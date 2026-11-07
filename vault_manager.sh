#!/usr/bin/env bash
# ==============================================================================
# Bitwarden / Vaultwarden Maintenance & Deduplication Engine
# Interactive CLI Wizard + Command-Line Automation with Visual Progress Bars
# ==============================================================================
# Features:
#   1. Interactive Wizard Mode: Guided menu, explicit plan review, and confirmation prompt.
#   2. Non-interactive CLI Mode: Direct parameter execution.
#   3. Offline Simulation Mode: Works via --file or --mock-bw without live Bitwarden.
#   4. KeePass Web URI Cleanup: Migrates URLs from notes & custom fields into login.uris.
#   5. Smart Name Restoration: Reconstructs titles as 'Domain (Username)'.
#   6. Multi-tier Duplicate Detection:
#        - exact: Strict comparison of all attributes. Timestamps must match.
#        - content: Payload comparison (Name, User, Password, URIs, Notes, Fields).
#        - partial: Merge candidates (matching domain + username, divergent fields).
#   7. Passkey Armor: Never proposes or executes deletions for fido2Credentials.
#   8. Real-time Progress Bar & ANSI box-drawing tables.
#
# Requirements: bash (>=4.0), jq
# ==============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="2.3.0"

# --- Configurations ---
MODE="preview"            # "preview" (default dry-run) or "apply"
INTERACTIVE=false         # Set to true when called with -i / --interactive or no arguments
EXEC_TARGET="local"       # "local", "docker", "file", or "mock"
DOCKER_CONTAINER=""
INPUT_FILE=""
OUTPUT_FILE=""
MOCK_BW_DIR=""
BW_CMD="bw"

# Terminal styling (protected against unset TERM / set -e failure)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    RED=$(tput setaf 1 2>/dev/null || true)
    GREEN=$(tput setaf 2 2>/dev/null || true)
    YELLOW=$(tput setaf 3 2>/dev/null || true)
    BLUE=$(tput setaf 4 2>/dev/null || true)
    MAGENTA=$(tput setaf 5 2>/dev/null || true)
    CYAN=$(tput setaf 6 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true)
    DIM=$(tput dim 2>/dev/null || true)
    RESET=$(tput sgr0 2>/dev/null || true)
elif [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    BOLD=''
    DIM=''
    RESET=''
fi

# --- UI Helpers ---
log_info() {
    printf " ${BLUE}ℹ${RESET} %s\n" "$*" >&2
}

log_success() {
    printf " ${GREEN}✔${RESET} %s\n" "$*" >&2
}

log_warn() {
    printf " ${YELLOW}▲${RESET} %s\n" "$*" >&2
}

log_error() {
    printf " ${RED}✖${RESET} %s\n" "$*" >&2
}

log_header() {
    local title="$1"
    local width=76
    printf "\n${BOLD}${CYAN}╭$(printf '─%.0s' $(seq 1 $width))╮${RESET}\n" >&2
    printf "${BOLD}${CYAN}│ %-${width}s │${RESET}\n" "  $title" >&2
    printf "${BOLD}${CYAN}╰$(printf '─%.0s' $(seq 1 $width))╯${RESET}\n\n" >&2
}

render_progress() {
    local current="$1"
    local total="$2"
    local label="${3:-Processing}"
    local bar_width=28

    if [[ "$total" -le 0 ]]; then
        total=1
    fi
    local percent=$((current * 100 / total))
    local filled=$((current * bar_width / total))
    local empty=$((bar_width - filled))

    local bar=""
    if [[ $filled -gt 0 ]]; then
        bar="$(printf "%0.s█" $(seq 1 "$filled"))"
    fi
    local spaces=""
    if [[ $empty -gt 0 ]]; then
        spaces="$(printf "%0.s░" $(seq 1 "$empty"))"
    fi

    printf "\r ${CYAN}⏳${RESET} %-22s [${GREEN}%s${DIM}%s${RESET}] %3d%% (%d/%d)" "$label" "$bar" "$spaces" "$percent" "$current" "$total" >&2
    if [[ "$current" -ge "$total" ]]; then
        printf "\n" >&2
    fi
}

# Interactive confirmation prompt
prompt_confirmation() {
    local action_description="$1"
    printf "\n${BOLD}${YELLOW}Action required:${RESET}\n" >&2
    printf "  Do you want to execute the planned operation ${BOLD}%s${RESET} now?\n" "$action_description" >&2
    printf "  [y/N] (Default: No, Cancel): " >&2
    
    local choice
    if [[ -t 0 ]]; then
        read -r choice </dev/tty || choice="n"
    else
        read -r choice || choice="n"
    fi
    case "$choice" in
        [yY]|[yY][eE][sS]|[jJ]|[jJ][aA])
            return 0
            ;;
        *)
            log_warn "Operation cancelled. No data was modified."
            return 1
            ;;
    esac
}

usage() {
    local exit_code="${1:-1}"
    cat <<EOF
${BOLD}Vaultwarden & Bitwarden Maintenance Engine v${VERSION}${RESET}

Usage: $SCRIPT_NAME [OPTIONS] [COMMAND]

${BOLD}Interactive Mode:${RESET}
  $SCRIPT_NAME -i               Start interactive wizard (guided menu, plan preview, confirmation)

${BOLD}Commands:${RESET}
  ${CYAN}fix-uris${RESET}             Extract URLs from notes/fields into login.uris (KeePass cleanup)
  ${CYAN}fix-names${RESET}            Generate meaningful names for entries with empty/raw URL titles
  ${CYAN}find-duplicates${RESET}      Locate duplicate items across multiple strictness tiers:
                         --tier exact    : Strict. Timestamps (creation/revision) must match.
                         --tier content  : Payload match. Ignores timestamps and IDs.
                         --tier partial  : Identifies merge candidates (same domain & user, differing fields).
  ${CYAN}merge-duplicates${RESET}     Consolidate fields into canonical item and prepare safe deletion list
  ${CYAN}duplicates${RESET}           Combined duplicate workflow: full audit, tier breakdown & resolution
  ${CYAN}test-run${RESET}             Execute offline simulation test suite

${BOLD}Options:${RESET}
  -i, --interactive    Interactive wizard mode with step-by-step confirmation
  --file <path>        Operate on a local JSON export file directly (no bw instance required)
  --mock-bw <dir>      Simulate a live Bitwarden CLI environment using a mock state directory
  --docker <container> Run 'bw' commands inside specified Docker container (e.g. --docker vaultwarden-cli)
  --apply              Apply modifications directly (Default is DRY-RUN preview only)
  --output <path>      Save modified JSON to file (when using --file)
  --tier <name>        Duplicate detection tier: 'exact' (default), 'content', 'partial'
  -h, --help           Show this help message

${BOLD}Examples:${RESET}
  # Interactive Wizard:
  $SCRIPT_NAME --interactive --mock-bw tests/mock_vault

  # Direct CLI preview:
  $SCRIPT_NAME --file tests/fixture_duplicates.json find-duplicates --tier content
EOF
    exit "$exit_code"
}

check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "'jq' is required but not installed. Please install jq."
        exit 1
    fi
}

fetch_vault_json() {
    if [[ "$EXEC_TARGET" == "file" ]]; then
        if [[ ! -f "$INPUT_FILE" ]]; then
            log_error "File not found: $INPUT_FILE"
            exit 1
        fi
        cat "$INPUT_FILE"
    elif [[ "$EXEC_TARGET" == "mock" ]]; then
        if [[ ! -f "$MOCK_BW_DIR/items.json" ]]; then
            if [[ -f "$MOCK_BW_DIR/mock_vault/items.json" ]]; then
                MOCK_BW_DIR="$MOCK_BW_DIR/mock_vault"
            else
                log_error "Mock vault state not found at: $MOCK_BW_DIR/items.json"
                exit 1
            fi
        fi
        cat "$MOCK_BW_DIR/items.json"
    elif [[ "$EXEC_TARGET" == "docker" ]]; then
        docker exec -i "$DOCKER_CONTAINER" bw list items
    else
        if ! command -v bw >/dev/null 2>&1; then
            log_error "Bitwarden CLI 'bw' not found in PATH. Use --file <path> or --mock-bw <dir> to test offline."
            exit 1
        fi
        bw list items
    fi
}

apply_deletions() {
    local ids_to_delete=($1)
    local total="${#ids_to_delete[@]}"
    local current=0

    printf "\n" >&2
    log_info "Applying deletions for $total items..."
    for id in "${ids_to_delete[@]}"; do
        current=$((current + 1))
        render_progress "$current" "$total" "Deleting items"
        
        if [[ "$EXEC_TARGET" == "mock" ]]; then
            jq --arg item_id "$id" 'map(select(.id != $item_id))' "$MOCK_BW_DIR/items.json" > "$MOCK_BW_DIR/items.json.tmp"
            mv "$MOCK_BW_DIR/items.json.tmp" "$MOCK_BW_DIR/items.json"
        elif [[ "$EXEC_TARGET" == "docker" ]]; then
            docker exec "$DOCKER_CONTAINER" bw delete item "$id" >/dev/null 2>&1 || true
        elif [[ "$EXEC_TARGET" == "local" ]]; then
            bw delete item "$id" >/dev/null 2>&1 || true
        fi
    done
}

# --- OPERATION 1: Fix URIs (KeePass Cleanup) ---
op_fix_uris() {
    local raw_json="$1"
    log_header "OPERATION: Fix KeePass Web Match URIs"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress "$total_items" "$total_items" "Scanning items"

    local transformed_json
    transformed_json=$(echo "$raw_json" | jq '
      def extract_urls_from_text:
        [scan("(https?://[a-zA-Z0-9./?=_-]+)")] | map({uri: .[0], match: 0});

      map(
        if .type == 1 then
          . as $item |
          ($item.notes // "" | extract_urls_from_text) as $note_urls |
          ([$item.fields[]? | select(.type == 0 and (.value | test("^https?://")))? | {uri: .value, match: 0}]) as $field_urls |
          ($note_urls + $field_urls) as $found_urls |
          ($item.login.uris // []) as $existing_uris |
          ($found_urls | map(select(.uri as $u | ($existing_uris | map(.uri) | index($u)) == null))) as $new_uris |
          
          if ($new_uris | length) > 0 then
            .login.uris = ($existing_uris + $new_uris) |
            ._modified = true |
            ._added_uris = ($new_uris | map(.uri))
          else
            .
          end
        else
          .
        end
      )
    ')

    local modified_count
    modified_count=$(echo "$transformed_json" | jq '[.[] | select(._modified == true)] | length')
    
    printf "\n" >&2
    log_info "Vault size: $total_items items"
    log_info "Items requiring URI migration: ${BOLD}$modified_count${RESET}"

    if [[ "$modified_count" -gt 0 ]]; then
        printf "\n${BOLD}%-36s │ %-25s │ %s${RESET}\n" "ITEM ID" "NAME" "MIGRATED URIS"
        printf "%s\n" "─────────────────────────────────────┼───────────────────────────┼─────────────────────────────────────"
        echo "$transformed_json" | jq -r '
          .[] | select(._modified == true) |
          "\(.id // "no-id")|\((.name // "N/A")[0:25])|\((._added_uris // []) | join(", "))"
        ' | awk -F '|' -v c1="$CYAN" -v r="$RESET" '{printf "%-36s │ %-25s │ " c1 "%s" r "\n", $1, $2, $3}'
    fi

    if [[ "$modified_count" -eq 0 ]]; then
        log_success "All entries already have clean web match URIs. Nothing to do."
        return 0
    fi

    # Interactive confirmation step
    if [[ "$INTERACTIVE" == true ]]; then
        if prompt_confirmation "Update $modified_count item(s)"; then
            MODE="apply"
        else
            return 0
        fi
    fi

    if [[ "$MODE" == "preview" ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No changes written. Run with -i or --apply to execute."
    elif [[ "$EXEC_TARGET" == "mock" ]]; then
        echo "$transformed_json" | jq 'map(del(._modified, ._added_uris))' > "$MOCK_BW_DIR/items.json"
        log_success "[MOCK BW] $modified_count item(s) updated in $MOCK_BW_DIR/items.json."
    elif [[ -n "$OUTPUT_FILE" ]]; then
        echo "$transformed_json" | jq 'map(del(._modified, ._added_uris))' > "$OUTPUT_FILE"
        log_success "$modified_count updated item(s) saved to: $OUTPUT_FILE"
    else
        log_info "Sending updates to Bitwarden CLI..."
        local items_to_update
        items_to_update=$(echo "$transformed_json" | jq -c '.[] | select(._modified == true) | del(._modified, ._added_uris)')
        local curr=0
        while IFS= read -r item_json; do
            [[ -z "$item_json" ]] && continue
            curr=$((curr + 1))
            render_progress "$curr" "$modified_count" "Updating items"
            local item_id
            item_id=$(echo "$item_json" | jq -r '.id')
            local encoded_item
            encoded_item=$(echo "$item_json" | bw encode)
            if [[ "$EXEC_TARGET" == "docker" ]]; then
                docker exec -i "$DOCKER_CONTAINER" bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
            else
                bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
            fi
        done <<< "$items_to_update"
        log_success "$modified_count item(s) successfully updated."
    fi
}

# --- OPERATION 2: Fix Missing / Generic Names ---
op_fix_names() {
    local raw_json="$1"
    log_header "OPERATION: Restore Descriptive Entry Names"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress "$total_items" "$total_items" "Scanning items"

    local transformed_json
    transformed_json=$(echo "$raw_json" | jq '
      def extract_domain(uri):
        if uri == null or uri == "" then ""
        else
          (uri | sub("^https?://"; "") | sub("^www\\."; "") | split("/")[0] | split(":")[0])
        end;

      map(
        if .type == 1 then
          . as $item |
          ($item.login.uris[0].uri // "") as $uri |
          ($item.login.username // "") as $user |
          extract_domain($uri) as $dom |
          
          ($item.name == null or $item.name == "" or ($item.name | test("^https?://")) or $item.name == $uri) as $is_generic |
          
          if $is_generic and ($dom != "" or $user != "") then
            (if $dom != "" and $user != "" then
               "\($dom) (\($user))"
             elif $dom != "" then
               $dom
             else
               "Account (\($user))"
             end) as $generated_name |
            
            if $item.name != $generated_name then
              ._old_name = ($item.name // "<empty>") |
              .name = $generated_name |
              ._modified = true
            else
              .
            end
          else
            .
          end
        else
          .
        end
      )
    ')

    local modified_count
    modified_count=$(echo "$transformed_json" | jq '[.[] | select(._modified == true)] | length')

    printf "\n" >&2
    log_info "Vault size: $total_items items"
    log_info "Items with generic/missing names: ${BOLD}$modified_count${RESET}"

    if [[ "$modified_count" -gt 0 ]]; then
        printf "\n${BOLD}%-36s │ %-30s ➔ %-35s${RESET}\n" "ITEM ID" "CURRENT NAME" "PROPOSED DESCRIPTIVE NAME"
        printf "%s\n" "─────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────"
        echo "$transformed_json" | jq -r '
          .[] | select(._modified == true) |
          "\(.id // "no-id")|\(._old_name[0:30])|\(.name)"
        ' | awk -F '|' -v c1="$YELLOW" -v c2="$GREEN" -v r="$RESET" '{printf "%-36s │ " c1 "%-30s" r " ➔ " c2 "%s" r "\n", $1, $2, $3}'
    fi

    if [[ "$modified_count" -eq 0 ]]; then
        log_success "All entries already have descriptive names. Nothing to do."
        return 0
    fi

    if [[ "$INTERACTIVE" == true ]]; then
        if prompt_confirmation "Rename $modified_count item(s)"; then
            MODE="apply"
        else
            return 0
        fi
    fi

    if [[ "$MODE" == "preview" ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No names modified. Run with -i or --apply to execute."
    elif [[ "$EXEC_TARGET" == "mock" ]]; then
        echo "$transformed_json" | jq 'map(del(._modified, ._old_name))' > "$MOCK_BW_DIR/items.json"
        log_success "[MOCK BW] $modified_count name(s) updated in $MOCK_BW_DIR/items.json."
    elif [[ -n "$OUTPUT_FILE" ]]; then
        echo "$transformed_json" | jq 'map(del(._modified, ._old_name))' > "$OUTPUT_FILE"
        log_success "$modified_count renamed item(s) saved to: $OUTPUT_FILE"
    else
        log_info "Sending name changes to Bitwarden CLI..."
        local items_to_update
        items_to_update=$(echo "$transformed_json" | jq -c '.[] | select(._modified == true) | del(._modified, ._old_name)')
        local curr=0
        while IFS= read -r item_json; do
            [[ -z "$item_json" ]] && continue
            curr=$((curr + 1))
            render_progress "$curr" "$modified_count" "Updating items"
            local item_id
            item_id=$(echo "$item_json" | jq -r '.id')
            local encoded_item
            encoded_item=$(echo "$item_json" | bw encode)
            if [[ "$EXEC_TARGET" == "docker" ]]; then
                docker exec -i "$DOCKER_CONTAINER" bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
            else
                bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
            fi
        done <<< "$items_to_update"
        log_success "$modified_count item(s) successfully updated."
    fi
}

# --- DUPLICATE DETECTION ENGINES ---
compute_exact_duplicates() {
    local raw_json="$1"
    echo "$raw_json" | jq '
      def has_pk: (.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0);
      group_by(del(.id)) |
      map(select(length > 1)) |
      map(
        sort_by(if has_pk then 0 else 1 end) |
        {
          count: length,
          canonical_id: .[0].id,
          name: .[0].name,
          username: .[0].login.username,
          duplicate_ids: (.[1:] | map(.id)),
          has_passkey: ([.[].login.fido2Credentials? | select(. != null and length > 0)] | length > 0)
        }
      )
    '
}

compute_content_duplicates() {
    local raw_json="$1"
    echo "$raw_json" | jq '
      def has_pk: (.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0);
      group_by({
        type: .type,
        name: .name,
        login: {
          username: .login.username,
          password: .login.password,
          uris: (.login.uris // [] | map(.uri) | sort)
        },
        notes: .notes,
        fields: (.fields // [] | sort_by(.name))
      }) |
      map(select(length > 1)) |
      map(
        sort_by(if has_pk then 0 else 1 end) |
        {
          count: length,
          canonical_id: .[0].id,
          name: .[0].name,
          username: .[0].login.username,
          duplicate_ids: (.[1:] | map(.id)),
          passkey_items: [ .[] | select(.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0) | .id ]
        }
      )
    '
}

compute_partial_duplicates() {
    local raw_json="$1"
    echo "$raw_json" | jq '
      def extract_domain(uri):
        if uri == null or uri == "" then ""
        else
          (uri | sub("^https?://"; "") | sub("^www\\."; "") | split("/")[0] | split(":")[0])
        end;

      map(select(.type == 1)) |
      group_by({
        user: (.login.username // "" | ascii_downcase),
        dom: extract_domain(.login.uris[0].uri // "")
      } | select(.user != "" and .dom != "")) |
      map(select(length > 1)) |
      map({
        domain: (.[0].login.uris[0].uri // "" | sub("^https?://"; "") | split("/")[0]),
        username: .[0].login.username,
        item_count: length,
        items: map({
          id: .id,
          name: .name,
          has_pw: (.login.password != null and .login.password != ""),
          has_passkey: (.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0),
          field_count: (.fields // [] | length),
          has_notes: (.notes != null and .notes != "")
        })
      })
    '
}

compute_merge_plan() {
    local raw_json="$1"
    echo "$raw_json" | jq '
      def has_passkey(item):
        (item.login.fido2Credentials != null and (item.login.fido2Credentials | length) > 0);

      map(select(.type == 1 and .login.username != null and .login.username != "")) |
      group_by({
        u: .login.username,
        p: .login.password
      }) |
      map(select(length > 1)) as $clusters |

      [ $clusters[] |
        sort_by(if has_passkey(.) then 0 else 1 end) as $sorted |
        $sorted[0] as $canonical |
        $sorted[1:] as $redundants |

        ($redundants | map(select(has_passkey(.))) | length) as $unsafe_passkeys |
        
        if $unsafe_passkeys > 0 then
          {
            status: "CONFLICT_MULTIPLE_PASSKEYS",
            canonical_id: $canonical.id,
            name: $canonical.name,
            username: $canonical.login.username,
            skip_deletion: true,
            redundant_ids_to_delete: [],
            reason: "Multiple items hold independent FIDO2 Passkeys"
          }
        else
          ($redundants | map(.notes // "") | join("\n---\n")) as $extra_notes |
          ([$redundants[].fields[]?] // []) as $extra_fields |
          ([$redundants[].login.uris[]?] // []) as $extra_uris |

          ($canonical |
            .notes = (if (.notes // "") == "" then $extra_notes else (.notes + (if $extra_notes == "" then "" else "\n---\n" + $extra_notes end)) end) |
            .fields = ((.fields // []) + $extra_fields | unique_by(.name)) |
            .login.uris = ((.login.uris // []) + $extra_uris | unique_by(.uri))
          ) as $merged_item |

          {
            status: "MERGED",
            canonical_id: $canonical.id,
            name: $canonical.name,
            username: $canonical.login.username,
            redundant_ids_to_delete: ($redundants | map(.id)),
            merged_item: $merged_item
          }
        end
      ]
    '
}

# --- TABLE PRESENTERS ---
print_exact_duplicates_table() {
    local exact_dups="$1"
    local group_count
    group_count=$(echo "$exact_dups" | jq 'length')

    log_info "Exact duplicate clusters: ${BOLD}$group_count${RESET} (requires identical creation & revision dates)"
    if [[ "$group_count" -gt 0 ]]; then
        printf "\n${BOLD}%-25s │ %-22s │ %-5s │ %-10s │ %s${RESET}\n" "NAME" "USERNAME" "ITEMS" "PASSKEY?" "REDUNDANT CANDIDATE IDS"
        printf "%s\n" "──────────────────────────┼────────────────────────┼───────┼────────────┼──────────────────────────────────────"
        echo "$exact_dups" | jq -r '.[] | "\(.name[0:25])|\(.username // "N/A")|\(.count)|\(if .has_passkey then "YES ⚠️" else "NO" end)|\(.duplicate_ids | join(", "))"' |
        awk -F '|' -v c1="$CYAN" -v c2="$YELLOW" -v r="$RESET" '{printf "%-25s │ %-22s │ " c1 "%-5s" r " │ " c2 "%-10s" r " │ %s\n", $1, $2, $3, $4, $5}'
    fi
}

print_content_duplicates_table() {
    local content_dups="$1"
    local group_count
    group_count=$(echo "$content_dups" | jq 'length')

    log_info "Content-identical duplicate clusters: ${BOLD}$group_count${RESET} (dates ignored)"
    if [[ "$group_count" -gt 0 ]]; then
        printf "\n${BOLD}%-25s │ %-22s │ %-5s │ %-12s │ %s${RESET}\n" "NAME" "USERNAME" "ITEMS" "PASSKEY STATUS" "REDUNDANT CANDIDATE IDS"
        printf "%s\n" "──────────────────────────┼────────────────────────┼───────┼──────────────┼──────────────────────────────────────"
        echo "$content_dups" | jq -r '.[] | "\(.name[0:25])|\(.username // "N/A")|\(.count)|\(if (.passkey_items | length) > 0 then "LOCKED 🔒" else "None" end)|\(.duplicate_ids | join(", "))"' |
        awk -F '|' -v c1="$CYAN" -v c2="$GREEN" -v r="$RESET" '{printf "%-25s │ %-22s │ " c1 "%-5s" r " │ " c2 "%-12s" r " │ %s\n", $1, $2, $3, $4, $5}'
    fi
}

print_partial_duplicates_table() {
    local partial_groups="$1"
    local group_count
    group_count=$(echo "$partial_groups" | jq 'length')

    log_info "Partial / Merge candidate clusters: ${BOLD}$group_count${RESET}"
    if [[ "$group_count" -gt 0 ]]; then
        printf "\n${BOLD}%-22s │ %-20s │ %s${RESET}\n" "DOMAIN" "USERNAME" "CANDIDATE ATTRIBUTE COMPARISON"
        printf "%s\n" "───────────────────────┼──────────────────────┼────────────────────────────────────────────────"
        echo "$partial_groups" | jq -r '.[] | "\(.domain[0:22])|\(.username[0:20])|\(.items | map("[\(.id[0:8])... pw:\(.has_pw) passkey:\(.has_passkey) fields:\(.field_count)]") | join(" vs "))"' |
        awk -F '|' -v c1="$CYAN" -v r="$RESET" '{printf "%-22s │ %-20s │ " c1 "%s" r "\n", $1, $2, $3}'
    fi
}

print_merge_plan_table() {
    local merge_result="$1"
    local merge_count
    merge_count=$(echo "$merge_result" | jq 'length')

    log_info "Duplicate clusters evaluated: ${BOLD}$merge_count${RESET}"
    if [[ "$merge_count" -gt 0 ]]; then
        printf "\n${BOLD}%-30s │ %-20s │ %-12s │ %s${RESET}\n" "ITEM NAME" "USERNAME" "STATUS" "REDUNDANT IDS TO DELETE"
        printf "%s\n" "───────────────────────────────┼──────────────────────┼──────────────┼──────────────────────────────────────"
        echo "$merge_result" | jq -r '
          .[] | "\(.name[0:30] // "N/A")|\(.username[0:20] // "N/A")|\(.status)|\((.redundant_ids_to_delete // []) | join(", "))"
        ' | awk -F '|' -v c1="$GREEN" -v c2="$YELLOW" -v r="$RESET" '{
            stat_col = ($3 == "MERGED" ? c1 : c2);
            printf "%-30s │ %-20s │ " stat_col "%-12s" r " │ %s\n", $1, $2, $3, $4
        }'
    fi
}

# --- OPERATION: Execute Merge Plan ---
execute_merge_plan() {
    local raw_json="$1"
    local merge_result="$2"
    local total_deletions="$3"

    print_merge_plan_table "$merge_result"
    printf "\n${YELLOW}Planned cleanup scope:${RESET} %d redundant item(s) to be removed (Passkeys strictly protected).\n" "$total_deletions"

    if [[ "$total_deletions" -eq 0 ]]; then
        log_success "No redundant items eligible for deletion."
        return 0
    fi

    if [[ "$INTERACTIVE" == true ]]; then
        if prompt_confirmation "Deletion of $total_deletions redundant duplicate(s)"; then
            MODE="apply"
        else
            return 0
        fi
    fi

    if [[ "$MODE" == "preview" ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No items deleted. Run with -i or --apply to execute."
    elif [[ "$MODE" == "apply" ]]; then
        local ids_to_delete
        ids_to_delete=$(echo "$merge_result" | jq -r '.[].redundant_ids_to_delete[]?')

        if [[ "$EXEC_TARGET" == "mock" ]]; then
            local merged_json
            merged_json=$(jq --argjson mr "$merge_result" '
              ($mr | map(select(.status == "MERGED")) | INDEX(.canonical_id)) as $canonical_map |
              ([$mr[].redundant_ids_to_delete[]?] | unique) as $del_ids |
              map(
                . as $item |
                if ($del_ids | index($item.id)) != null then
                  empty
                elif $canonical_map[$item.id] != null then
                  $canonical_map[$item.id].merged_item
                else
                  .
                end
              )
            ' "$MOCK_BW_DIR/items.json")
            echo "$merged_json" > "$MOCK_BW_DIR/items.json"
        elif [[ -n "$OUTPUT_FILE" ]]; then
            local merged_json
            merged_json=$(echo "$raw_json" | jq --argjson mr "$merge_result" '
              ($mr | map(select(.status == "MERGED")) | INDEX(.canonical_id)) as $canonical_map |
              ([$mr[].redundant_ids_to_delete[]?] | unique) as $del_ids |
              map(
                . as $item |
                if ($del_ids | index($item.id)) != null then
                  empty
                elif $canonical_map[$item.id] != null then
                  $canonical_map[$item.id].merged_item
                else
                  .
                end
              )
            ')
            echo "$merged_json" > "$OUTPUT_FILE"
            log_success "Cleaned vault data saved to: $OUTPUT_FILE"
        elif [[ "$EXEC_TARGET" == "docker" || "$EXEC_TARGET" == "local" ]]; then
            local items_to_update
            items_to_update=$(echo "$merge_result" | jq -c '.[] | select(.status == "MERGED") | .merged_item')
            while IFS= read -r item_json; do
                [[ -z "$item_json" ]] && continue
                local item_id
                item_id=$(echo "$item_json" | jq -r '.id')
                local encoded_item
                encoded_item=$(echo "$item_json" | bw encode)
                if [[ "$EXEC_TARGET" == "docker" ]]; then
                    docker exec -i "$DOCKER_CONTAINER" bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
                else
                    bw edit item "$item_id" "$encoded_item" >/dev/null 2>&1 || true
                fi
            done <<< "$items_to_update"
            apply_deletions "$ids_to_delete"
        fi
        log_success "Cleanup completed: $total_deletions duplicate(s) successfully removed."
    fi
}

# --- OPERATION: Find Duplicates Across Multi-Tier (CLI entry) ---
op_find_duplicates() {
    local raw_json="$1"
    local tier="${2:-exact}"

    log_header "OPERATION: Duplicate Detection [TIER: ${tier^^}]"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress "$total_items" "$total_items" "Scanning items"

    local passkey_count
    passkey_count=$(echo "$raw_json" | jq '[.[] | select(.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0)] | length')
    render_progress "$total_items" "$total_items" "Auditing passkeys"

    printf "\n" >&2
    log_info "Total vault items: $total_items"
    log_info "Passkey credentials detected: ${BOLD}$passkey_count${RESET} (Safety Armor Active)"

    case "$tier" in
        exact)
            local exact_dups
            exact_dups=$(compute_exact_duplicates "$raw_json")
            print_exact_duplicates_table "$exact_dups"
            ;;
        content)
            local content_dups
            content_dups=$(compute_content_duplicates "$raw_json")
            print_content_duplicates_table "$content_dups"
            ;;
        partial)
            local partial_groups
            partial_groups=$(compute_partial_duplicates "$raw_json")
            print_partial_duplicates_table "$partial_groups"
            ;;
        *)
            log_error "Unknown tier: $tier. Supported: exact, content, partial"
            exit 1
            ;;
    esac

    printf "\n" >&2
    log_warn "[DRY-RUN SAFETY] Passkeys and canonical records are isolated and protected."
}

# --- OPERATION: Merge Duplicates (CLI entry) ---
op_merge_duplicates() {
    local raw_json="$1"
    log_header "OPERATION: Merge Attributes & Calculate Safe Deletions"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress "$total_items" "$total_items" "Grouping accounts"

    local merge_result
    merge_result=$(compute_merge_plan "$raw_json")
    render_progress "$total_items" "$total_items" "Consolidating attributes"

    local total_deletions
    total_deletions=$(echo "$merge_result" | jq '[.[].redundant_ids_to_delete[]?] | length')

    execute_merge_plan "$raw_json" "$merge_result" "$total_deletions"
}

# --- OPERATION: Combined Smart Duplicate Workflow ---
op_duplicate_workflow() {
    local raw_json="$1"
    log_header "OPERATION: Smart Duplicate Analysis & Resolution"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress 1 4 "Scanning vault items"

    local passkey_count
    passkey_count=$(echo "$raw_json" | jq '[.[] | select(.login.fido2Credentials != null and (.login.fido2Credentials | length) > 0)] | length')
    render_progress 2 4 "Auditing passkeys"

    local exact_dups content_dups partial_groups merge_result
    exact_dups=$(compute_exact_duplicates "$raw_json")
    content_dups=$(compute_content_duplicates "$raw_json")
    render_progress 3 4 "Analyzing duplicate tiers"

    partial_groups=$(compute_partial_duplicates "$raw_json")
    merge_result=$(compute_merge_plan "$raw_json")
    render_progress 4 4 "Evaluating merge candidates"

    local exact_clusters content_clusters partial_clusters merge_clusters total_deletions passkey_conflicts
    exact_clusters=$(echo "$exact_dups" | jq 'length')
    content_clusters=$(echo "$content_dups" | jq 'length')
    partial_clusters=$(echo "$partial_groups" | jq 'length')
    merge_clusters=$(echo "$merge_result" | jq '[.[] | select(.status == "MERGED")] | length')
    total_deletions=$(echo "$merge_result" | jq '[.[].redundant_ids_to_delete[]?] | length')
    passkey_conflicts=$(echo "$merge_result" | jq '[.[] | select(.status == "CONFLICT_MULTIPLE_PASSKEYS")] | length')

    printf "\n" >&2
    printf "${BOLD}${CYAN}╭────────────────────────────────────────────────────────────────────────────╮${RESET}\n" >&2
    printf "${BOLD}${CYAN}│ %-74s │${RESET}\n" "  DUPLICATE AUDIT REPORT" >&2
    printf "${BOLD}${CYAN}╰────────────────────────────────────────────────────────────────────────────╯${RESET}\n" >&2
    printf "  • Total items scanned:              ${BOLD}%d${RESET}\n" "$total_items" >&2
    printf "  • Passkeys protected (Safety Armor): ${BOLD}%d 🔒${RESET}\n" "$passkey_count" >&2
    printf "  • Tier 1 Exact duplicate clusters:  ${BOLD}%d${RESET} (Identical data & timestamps)\n" "$exact_clusters" >&2
    printf "  • Tier 2 Content duplicate clusters:${BOLD}%d${RESET} (Identical data, timestamps ignored)\n" "$content_clusters" >&2
    printf "  • Tier 3 Partial match clusters:    ${BOLD}%d${RESET} (Same domain & username)\n" "$partial_clusters" >&2
    printf "  • Eligible merge clusters:          ${BOLD}%d${RESET}\n" "$merge_clusters" >&2
    if [[ "$passkey_conflicts" -gt 0 ]]; then
        printf "  • Passkey conflicts detected:       ${BOLD}${YELLOW}%d ⚠️${RESET} (Protected from merge)\n" "$passkey_conflicts" >&2
    fi
    printf "  • Redundant items safe to delete:   ${BOLD}%d${RESET}\n\n" "$total_deletions" >&2

    if [[ "$exact_clusters" -eq 0 && "$content_clusters" -eq 0 && "$partial_clusters" -eq 0 && "$total_deletions" -eq 0 ]]; then
        log_success "No duplicate items found in any tier. Your vault is clean."
        return 0
    fi

    # Interactive action prompt based on analysis findings
    while true; do
        printf "${BOLD}Duplicate Resolution Menu:${RESET}\n" >&2
        printf "  [1] Safe Merge & Cleanup (%d redundant item(s) to delete)\n" "$total_deletions" >&2
        printf "  [2] View Tier 1 details (Exact duplicates: %d cluster(s))\n" "$exact_clusters" >&2
        printf "  [3] View Tier 2 details (Content-identical: %d cluster(s))\n" "$content_clusters" >&2
        printf "  [4] View Tier 3 details (Partial matches: %d cluster(s))\n" "$partial_clusters" >&2
        printf "  [5] Preview complete merge & deletion plan table\n" >&2
        printf "  [b] Back to main menu\n\n" >&2
        printf "Selection [1-5, b]: " >&2

        local subchoice
        if [[ -t 0 ]]; then
            read -r subchoice </dev/tty || subchoice="b"
        else
            read -r subchoice || subchoice="b"
        fi

        case "$subchoice" in
            1)
                if [[ "$total_deletions" -eq 0 ]]; then
                    log_info "No redundant items eligible for deletion."
                else
                    execute_merge_plan "$raw_json" "$merge_result" "$total_deletions"
                fi
                break
                ;;
            2)
                print_exact_duplicates_table "$exact_dups"
                ;;
            3)
                print_content_duplicates_table "$content_dups"
                ;;
            4)
                print_partial_duplicates_table "$partial_groups"
                ;;
            5)
                print_merge_plan_table "$merge_result"
                ;;
            b|B)
                break
                ;;
            *)
                log_error "Invalid selection: $subchoice"
                ;;
        esac
        printf "\n" >&2
    done
}

# --- INTERACTIVE WIZARD MENU ---
run_interactive_wizard() {
    INTERACTIVE=true

    while true; do
        local raw_json
        raw_json="$(fetch_vault_json)"

        printf "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}\n"
        printf "${BOLD}${CYAN}║     VAULTWARDEN & BITWARDEN MAINTENANCE WIZARD                       ║${RESET}\n"
        printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}\n"
        printf " [1] Fix KeePass URLs (migrate URLs from notes/fields into URI matches)\n"
        printf " [2] Fix missing / generic names (restore 'Domain (Username)')\n"
        printf " [3] Analyze & resolve duplicates (smart multi-tier audit & merge)\n"
        printf " [q] Quit\n\n"
        printf "Selection [1-3, q]: "

        local menu_choice
        if [[ -t 0 ]]; then
            read -r menu_choice </dev/tty || menu_choice="q"
        else
            read -r menu_choice || menu_choice="q"
        fi

        case "$menu_choice" in
            1) op_fix_uris "$raw_json" ;;
            2) op_fix_names "$raw_json" ;;
            3) op_duplicate_workflow "$raw_json" ;;
            q|Q)
                log_info "Interactive wizard closed."
                break
                ;;
            *)
                log_error "Invalid selection: $menu_choice"
                ;;
        esac

        printf "\nPress Enter for main menu..."
        if [[ -t 0 ]]; then
            read -r _ </dev/tty || true
        else
            read -r _ || true
        fi
    done
}

# --- Main Entry Point ---
main() {
    check_dependencies

    local command=""
    local tier="exact"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            --file)
                INPUT_FILE="$2"
                EXEC_TARGET="file"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --mock-bw)
                MOCK_BW_DIR="$2"
                EXEC_TARGET="mock"
                shift 2
                ;;
            --docker)
                DOCKER_CONTAINER="$2"
                EXEC_TARGET="docker"
                shift 2
                ;;
            --apply)
                MODE="apply"
                shift
                ;;
            --tier)
                tier="$2"
                shift 2
                ;;
            -h|--help)
                usage 0
                ;;
            fix-uris|fix-names|find-duplicates|merge-duplicates|duplicates|test-run)
                command="$1"
                shift
                ;;
            *)
                log_error "Unknown argument or command: $1"
                usage
                ;;
        esac
    done

    # Normalize MOCK_BW_DIR if subfolder mock_vault exists
    if [[ "$EXEC_TARGET" == "mock" && -n "$MOCK_BW_DIR" ]]; then
        if [[ ! -f "$MOCK_BW_DIR/items.json" && -f "$MOCK_BW_DIR/mock_vault/items.json" ]]; then
            MOCK_BW_DIR="$MOCK_BW_DIR/mock_vault"
        fi
    fi

    # If no command passed and -i is requested (or invoked bare), enter wizard
    if [[ -z "$command" ]]; then
        if [[ "$INTERACTIVE" == true ]] || [[ $# -eq 0 && -t 0 ]]; then
            INTERACTIVE=true
        else
            log_error "No command specified. Use -i for interactive mode or -h for help."
            usage
        fi
    fi

    if [[ "$command" == "test-run" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$SCRIPT_DIR/tests/run_tests.sh" ]]; then
            exec "$SCRIPT_DIR/tests/run_tests.sh"
        elif [[ -f "./tests/run_tests.sh" ]]; then
            exec "./tests/run_tests.sh"
        else
            log_error "Test runner not found at ./tests/run_tests.sh"
            exit 1
        fi
    fi

    log_info "Initializing [Target: ${BOLD}$EXEC_TARGET${RESET}, Mode: ${BOLD}$MODE${RESET}, Interactive: ${BOLD}$INTERACTIVE${RESET}]"
    local vault_data
    vault_data="$(fetch_vault_json)"

    if [[ "$INTERACTIVE" == true && -z "$command" ]]; then
        run_interactive_wizard
        exit 0
    fi

    case "$command" in
        fix-uris)
            op_fix_uris "$vault_data"
            ;;
        fix-names)
            op_fix_names "$vault_data"
            ;;
        find-duplicates)
            op_find_duplicates "$vault_data" "$tier"
            ;;
        merge-duplicates)
            op_merge_duplicates "$vault_data"
            ;;
        duplicates)
            op_duplicate_workflow "$vault_data"
            ;;
    esac
}

main "$@"
