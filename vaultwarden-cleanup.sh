#!/usr/bin/env bash
# ==============================================================================
# vaultwarden-cleanup — Bitwarden / Vaultwarden Maintenance & Deduplication CLI
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
#        - content: Payload comparison (Name, User, Password, TOTP, URIs, Notes, Fields, Passkeys).
#        - partial: Audit view (same main domain + username + passkey status, incl. merge eligibility).
#   7. Passkey & TOTP Armor: Never merges/deletes differing passkeys or differing 2FA TOTP secrets.
#   8. Real-time Progress Bar & ANSI box-drawing tables.
#
# Requirements: bash (>=4.0), jq
# ==============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.5.0"

# --- Configurations ---
MODE="preview"            # "preview" (default dry-run) or "apply"
INTERACTIVE=false         # Set to true when called with -i / --interactive or no arguments
VERBOSE=false             # Set to true via -v / --verbose or wizard toggle
INCLUDE_EXISTING_URIS=false # By default fix-uris only updates entries without any URI; true with --all-uris
EXEC_TARGET="local"       # "local", "docker", "file", or "mock"
DOCKER_CONTAINER=""
INPUT_FILE=""
OUTPUT_FILE=""
MOCK_BW_DIR=""
LOCAL_BW_BIN="$SCRIPT_DIR/.bin/bw"
BW_CMD="bw"
SERVER_URL=""
BOOTSTRAP_BW=false
CONNECTED_ACCOUNT=""
DETECTED_SERVER_HINT=""
CAPTURED_STDOUT=""
CAPTURED_STDERR=""
VERBOSE_DECISION="no"
CONFIRM_ACTION="cancel"
WORKING_VAULT_JSON=""

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

trim_whitespace() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

flush_tty_input() {
    if [[ -t 0 ]] && [[ -r /dev/tty ]]; then
        local _i=0 _discard=""
        while (( _i < 16 )) && IFS= read -r -t 0 </dev/tty 2>/dev/null; do
            IFS= read -r -t 0.001 -n 4096 _discard </dev/tty 2>/dev/null || break
            _i=$((_i + 1))
        done
    fi
}

read_tty_line() {
    local __var_name="$1"
    local __line=""
    if [[ -t 0 ]] && [[ -r /dev/tty ]]; then
        IFS= read -r __line </dev/tty || __line=""
    else
        IFS= read -r __line || __line=""
    fi
    printf -v "$__var_name" '%s' "$__line"
}

read_tty_secret() {
    local __var_name="$1"
    local __secret=""
    if [[ -t 0 ]] && [[ -r /dev/tty ]]; then
        IFS= read -r -s __secret </dev/tty || __secret=""
        printf "\n" >&2
    else
        IFS= read -r __secret || __secret=""
    fi
    printf -v "$__var_name" '%s' "$__secret"
}

prompt_yes_default() {
    local question="$1"
    flush_tty_input
    printf "\n${BOLD}${YELLOW}Action required:${RESET}\n" >&2
    printf "  %s\n" "$question" >&2
    printf "  [Y/n] (Default: Yes): " >&2

    local choice=""
    read_tty_line choice
    choice="$(trim_whitespace "$choice")"
    case "$choice" in
        ""|[yY]|[yY][eE][sS]|[jJ]|[jJ][aA])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Interactive confirmation prompt
prompt_confirmation() {
    local action_description="$1"
    CONFIRM_ACTION="cancel"
    flush_tty_input
    while true; do
        printf "\n${BOLD}${YELLOW}Action required:${RESET}\n" >&2
        printf "  Do you want to execute the planned operation ${BOLD}%s${RESET} now?\n" "$action_description" >&2
        printf "  [y] Yes (apply all)  [v] Verify one-by-one  [N] No, Cancel (Default): " >&2

        local choice=""
        read_tty_line choice
        choice="$(trim_whitespace "$choice")"
        case "$choice" in
            [yY]|[yY][eE][sS]|[jJ]|[jJ][aA])
                CONFIRM_ACTION="all"
                return 0
                ;;
            [vV]|[vV][eE][rR][iI][fF][yY])
                CONFIRM_ACTION="verify"
                return 0
                ;;
            ""|[nN]|[nN][oO]|[nN][eE][iI][nN])
                CONFIRM_ACTION="cancel"
                log_warn "Operation cancelled. No data was modified."
                return 1
                ;;
            *)
                log_error "Please enter y (apply all), v (verify one-by-one), or n (cancel)."
                ;;
        esac
    done
}

# Interactive per-item confirmation prompt (used in interactive + verbose mode)
prompt_verbose_item_decision() {
    local label="$1"
    flush_tty_input
    while true; do
        printf "\n  ${BOLD}${YELLOW}%s${RESET}\n" "$label" >&2
        printf "  [y] Apply  [n] Skip (Default)  [a] Apply all remaining  [q] Cancel remaining: " >&2
        local choice=""
        read_tty_line choice
        choice="$(trim_whitespace "$choice")"
        case "$choice" in
            [yY]|[yY][eE][sS]|[jJ]|[jJ][aA])
                VERBOSE_DECISION="yes"
                return 0
                ;;
            ""|[nN]|[nN][oO]|[nN][eE][iI][nN])
                VERBOSE_DECISION="no"
                return 0
                ;;
            [aA]|[aA][lL][lL])
                VERBOSE_DECISION="all"
                return 0
                ;;
            [qQ]|[qQ][uU][iI][tT])
                VERBOSE_DECISION="quit"
                return 0
                ;;
            *)
                log_error "Please enter y (apply), n (skip), a (apply all remaining), or q (cancel)."
                ;;
        esac
    done
}

usage() {
    local exit_code="${1:-1}"
    cat <<EOF
${BOLD}vaultwarden-cleanup v${VERSION}${RESET} (Bitwarden / Vaultwarden Cleanup CLI)

Usage: $SCRIPT_NAME [OPTIONS] [COMMAND]

${BOLD}Interactive Mode:${RESET}
  $SCRIPT_NAME -i               Start interactive wizard (auto-bootstraps 'bw', login/unlock, plan & confirm)
  $SCRIPT_NAME -i -v            Start wizard in verbose mode (per-item diff & step-by-step [y/n/a/q] prompt)

${BOLD}Commands:${RESET}
  ${CYAN}fix-uris${RESET}             Extract URLs from notes/fields into login.uris (default: only entries without any URL)
  ${CYAN}fix-names${RESET}            Generate names ('Domain (Username)') for entries without a name or named '--'
  ${CYAN}find-duplicates${RESET}      Locate duplicate items across multiple strictness tiers:
                         --tier exact    : Strict. Timestamps (creation/revision) must match.
                         --tier content  : Payload match. Ignores timestamps and IDs.
                         --tier partial  : Audit view (same main domain & username; shows whether mergeable or audit-only).
  ${CYAN}merge-duplicates${RESET}     Consolidate fields into canonical item and prepare safe deletion list
  ${CYAN}duplicates${RESET}           Combined duplicate workflow: full audit, tier breakdown & resolution
  ${CYAN}test-run${RESET}             Execute offline simulation test suite

${BOLD}Options:${RESET}
  -i, --interactive    Interactive wizard mode with step-by-step confirmation
  -v, --verbose        Show full per-item before/after diffs (secrets masked) & step-by-step prompts
  --server <url>       Vaultwarden / Bitwarden server URL (e.g. https://vault.example.com)
  --bootstrap-bw       Automatically download standalone 'bw' CLI into ./.bin/bw if missing
  --file <path>        Operate on a local JSON export file directly (no bw instance required)
  --mock-bw <dir>      Simulate a live Bitwarden CLI environment using a mock state directory
  --docker <container> Run 'bw' inside a Bitwarden CLI container (not the vaultwarden/server container)
  --apply              Apply modifications directly (Default is DRY-RUN preview only)
  --all-uris           With 'fix-uris', also append URLs found in notes/fields to items that already have URIs
  --output <path>      Save modified JSON to file (when using --file)
  --tier <name>        Duplicate detection tier: 'exact' (default), 'content', 'partial'
  -h, --help           Show this help message

${BOLD}Examples:${RESET}
  # Live Interactive Wizard in Verbose Mode:
  $SCRIPT_NAME -i -v --server https://vault.example.com

  # Offline Interactive Wizard (simulation):
  $SCRIPT_NAME --interactive --mock-bw tests/mock_vault

  # Verbose Dry-Run CLI preview:
  $SCRIPT_NAME -v --file tests/fixture_duplicates.json merge-duplicates
EOF
    exit "$exit_code"
}

check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "'jq' is required but not installed. Please install jq."
        exit 1
    fi
}

normalize_server_url() {
    local url="${1:-}"
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    if [[ -z "$url" || "$url" == "null" ]]; then
        printf ''
        return 0
    fi
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi
    url="${url%/}"
    printf '%s' "$url"
}

detect_vaultwarden_domain_hint() {
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    local cid domain=""
    if [[ -n "$DOCKER_CONTAINER" ]]; then
        domain="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DOCKER_CONTAINER" 2>/dev/null | sed -n 's/^DOMAIN=//p' | head -n 1 || true)"
    fi
    if [[ -z "$domain" ]]; then
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            domain="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | sed -n 's/^DOMAIN=//p' | head -n 1 || true)"
            [[ -n "$domain" ]] && break
        done < <(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /vaultwarden|bitwarden/ {print $1}' || true)
    fi
    if [[ -n "$domain" ]]; then
        normalize_server_url "$domain"
    fi
}

run_bw_exec() {
    if [[ "$EXEC_TARGET" == "docker" ]]; then
        local -a d_args=()
        if [[ "${1:-}" == "--stdin" ]]; then
            d_args+=(-i)
            shift
        elif [[ "${1:-}" == "--tty" ]]; then
            d_args+=(-it)
            shift
        fi
        [[ -n "${BW_SESSION:-}" ]] && d_args+=(-e BW_SESSION)
        [[ -n "${BW_PASSWORD:-}" ]] && d_args+=(-e BW_PASSWORD)
        [[ -n "${BW_CLIENTID:-}" ]] && d_args+=(-e BW_CLIENTID)
        [[ -n "${BW_CLIENTSECRET:-}" ]] && d_args+=(-e BW_CLIENTSECRET)
        [[ -n "${NODE_TLS_REJECT_UNAUTHORIZED:-}" ]] && d_args+=(-e NODE_TLS_REJECT_UNAUTHORIZED)
        [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]] && d_args+=(-e NODE_EXTRA_CA_CERTS)

        BW_SESSION="${BW_SESSION:-}" \
        BW_PASSWORD="${BW_PASSWORD:-}" \
        BW_CLIENTID="${BW_CLIENTID:-}" \
        BW_CLIENTSECRET="${BW_CLIENTSECRET:-}" \
        docker exec ${d_args[@]+"${d_args[@]}"} "$DOCKER_CONTAINER" bw "$@"
    else
        if [[ "${1:-}" == "--stdin" || "${1:-}" == "--tty" ]]; then
            shift
        fi
        "$BW_CMD" "$@"
    fi
}

run_bw_capture() {
    CAPTURED_STDOUT=""
    CAPTURED_STDERR=""
    local out_file err_file rc=0
    out_file="$(mktemp)"
    err_file="$(mktemp)"
    run_bw_exec "$@" </dev/null >"$out_file" 2>"$err_file" || rc=$?
    CAPTURED_STDOUT="$(cat "$out_file")"
    CAPTURED_STDERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
    return "$rc"
}

run_bw_stdin() {
    local stdin_payload="$1"
    shift
    CAPTURED_STDOUT=""
    CAPTURED_STDERR=""
    local out_file err_file rc=0
    out_file="$(mktemp)"
    err_file="$(mktemp)"
    printf '%s' "$stdin_payload" | run_bw_exec --stdin "$@" >"$out_file" 2>"$err_file" || rc=$?
    CAPTURED_STDOUT="$(cat "$out_file")"
    CAPTURED_STDERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
    return "$rc"
}

print_bw_error_details() {
    local combined="${CAPTURED_STDERR}${CAPTURED_STDOUT:+
$CAPTURED_STDOUT}"
    [[ -n "$CAPTURED_STDERR" ]] && printf "  %s\n" "$CAPTURED_STDERR" >&2
    if [[ -n "$CAPTURED_STDOUT" && "$CAPTURED_STDOUT" != "$CAPTURED_STDERR" ]]; then
        printf "  %s\n" "$CAPTURED_STDOUT" >&2
    fi
    if [[ "$combined" =~ SELF_SIGNED_CERT|UNABLE_TO_VERIFY_LEAF_SIGNATURE|CERT_HAS_EXPIRED|DEPTH_ZERO_SELF_SIGNED_CERT ]]; then
        log_warn "TLS certificate error detected. For self-signed certs, set NODE_EXTRA_CA_CERTS=/path/to/ca.pem (or NODE_TLS_REJECT_UNAUTHORIZED=0 on trusted networks)."
    fi
}

bootstrap_bw_cli() {
    local os_name arch_name platform
    os_name="$(uname -s 2>/dev/null || echo "Linux")"
    arch_name="$(uname -m 2>/dev/null || echo "x86_64")"

    case "$os_name" in
        Linux*)  platform="linux" ;;
        Darwin*) platform="macos" ;;
        *)
            log_error "Unsupported OS for automatic 'bw' bootstrap: $os_name. Please install Bitwarden CLI manually."
            return 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_error "Neither 'curl' nor 'wget' is installed. Cannot download Bitwarden CLI."
        return 1
    fi

    local base_redirect_url="https://vault.bitwarden.com/download/?app=cli&platform=${platform}"
    local dl_url="$base_redirect_url"

    if [[ "$arch_name" == "aarch64" || "$arch_name" == "arm64" ]]; then
        local resolved_loc=""
        if command -v curl >/dev/null 2>&1; then
            resolved_loc="$(curl -fsSI "$base_redirect_url" 2>/dev/null | awk 'tolower($1) == "location:" {sub(/\r$/, "", $2); print $2; exit}' || true)"
        elif command -v wget >/dev/null 2>&1; then
            resolved_loc="$(wget --spider -S --max-redirect=0 "$base_redirect_url" 2>&1 | awk 'tolower($1) == "location:" {sub(/\r$/, "", $2); print $2; exit}' || true)"
        fi
        if [[ -n "$resolved_loc" ]]; then
            dl_url="${resolved_loc/bw-${platform}-/bw-${platform}-arm64-}"
        else
            log_warn "Could not resolve ARM64 redirect header; attempting standard download URL."
        fi
    fi

    local bin_dir
    bin_dir="$(dirname "$LOCAL_BW_BIN")"
    mkdir -p "$bin_dir"

    local tmp_zip
    tmp_zip="$(mktemp "${TMPDIR:-/tmp}/bw-cli-XXXXXX.zip")"

    log_info "Downloading standalone Bitwarden CLI ($os_name / $arch_name)..."
    local dl_rc=0
    if command -v curl >/dev/null 2>&1; then
        if [[ -t 2 ]]; then
            curl -fL --progress-bar "$dl_url" -o "$tmp_zip" || dl_rc=$?
        else
            curl -fsSL "$dl_url" -o "$tmp_zip" || dl_rc=$?
        fi
    else
        wget -q --show-progress -O "$tmp_zip" "$dl_url" 2>/dev/null || wget -q -O "$tmp_zip" "$dl_url" || dl_rc=$?
    fi

    if [[ $dl_rc -ne 0 || ! -s "$tmp_zip" ]]; then
        rm -f "$tmp_zip"
        log_error "Failed to download Bitwarden CLI from: $dl_url"
        return 1
    fi

    log_info "Extracting Bitwarden CLI into $LOCAL_BW_BIN..."
    local ext_rc=0
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$tmp_zip" -d "$bin_dir" || ext_rc=$?
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$tmp_zip" "$bin_dir" || ext_rc=$?
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$tmp_zip" -C "$bin_dir" || ext_rc=$?
    else
        rm -f "$tmp_zip"
        log_error "Cannot extract archive: please install 'unzip' or 'python3' (e.g. apt-get install -y unzip)."
        return 1
    fi
    rm -f "$tmp_zip"

    if [[ $ext_rc -ne 0 || ! -f "$LOCAL_BW_BIN" ]]; then
        log_error "Extraction failed: '$LOCAL_BW_BIN' was not found after unpacking."
        return 1
    fi

    chmod +x "$LOCAL_BW_BIN"
    local bw_ver=""
    if ! bw_ver="$("$LOCAL_BW_BIN" --version 2>/dev/null)"; then
        log_error "Downloaded '$LOCAL_BW_BIN' failed verification ('bw --version')."
        return 1
    fi

    BW_CMD="$LOCAL_BW_BIN"
    log_success "Bitwarden CLI v${bw_ver} installed at $LOCAL_BW_BIN"
    return 0
}

ensure_bw_cli() {
    if command -v bw >/dev/null 2>&1; then
        BW_CMD="$(command -v bw)"
        return 0
    fi
    if [[ -x "$LOCAL_BW_BIN" ]]; then
        BW_CMD="$LOCAL_BW_BIN"
        log_info "Using local Bitwarden CLI: $LOCAL_BW_BIN"
        return 0
    fi

    log_warn "Bitwarden CLI ('bw') was not found in PATH or $LOCAL_BW_BIN."
    if [[ "$BOOTSTRAP_BW" == true ]]; then
        bootstrap_bw_cli || exit 1
        return 0
    elif [[ "$INTERACTIVE" == true ]]; then
        if prompt_yes_default "Download official standalone Bitwarden CLI into $LOCAL_BW_BIN now?"; then
            bootstrap_bw_cli || exit 1
            return 0
        fi
        log_error "Bitwarden CLI is required to connect to a live vault."
        exit 1
    else
        log_error "Bitwarden CLI 'bw' not found. Run with '-i' or '--bootstrap-bw' to auto-install into ./.bin/bw, or use --file <path>."
        exit 1
    fi
}

ensure_bw_authenticated() {
    while true; do
        local st_rc=0
        run_bw_capture status --nointeraction || st_rc=$?
        if [[ $st_rc -ne 0 ]] && ! printf '%s' "$CAPTURED_STDOUT" | jq -e '.status' >/dev/null 2>&1; then
            log_error "Failed to query Bitwarden CLI status:"
            print_bw_error_details
            exit 1
        fi

        local status current_server current_email norm_current
        status="$(printf '%s' "$CAPTURED_STDOUT" | jq -r '.status // "unauthenticated"' 2>/dev/null || echo "unauthenticated")"
        current_server="$(printf '%s' "$CAPTURED_STDOUT" | jq -r '.serverUrl // empty' 2>/dev/null || true)"
        current_email="$(printf '%s' "$CAPTURED_STDOUT" | jq -r '.userEmail // empty' 2>/dev/null || true)"
        norm_current="$(normalize_server_url "$current_server")"

        if [[ -n "$SERVER_URL" ]]; then
            local norm_target
            norm_target="$(normalize_server_url "$SERVER_URL")"
            if [[ "$status" != "unauthenticated" && -n "$norm_current" && "$norm_current" != "$norm_target" ]]; then
                if [[ "$INTERACTIVE" == true ]]; then
                    if prompt_yes_default "Bitwarden CLI is currently logged into '$current_server'. Logout and switch to '$norm_target'?"; then
                        run_bw_capture logout --nointeraction || true
                        BW_SESSION=""
                        export BW_SESSION
                        continue
                    else
                        exit 1
                    fi
                else
                    log_error "Bitwarden CLI is logged into '$current_server', not '$norm_target'. Run 'bw logout' first or use '-i'."
                    exit 1
                fi
            elif [[ "$status" == "unauthenticated" && "$norm_current" != "$norm_target" ]]; then
                if ! run_bw_capture config server "$norm_target" --nointeraction; then
                    log_error "Failed to configure server URL '$norm_target':"
                    print_bw_error_details
                    exit 1
                fi
                current_server="$norm_target"
                norm_current="$norm_target"
            fi
        fi

        if [[ "$status" == "unlocked" ]]; then
            CONNECTED_ACCOUNT="${current_email:-authenticated} @ ${current_server:-default}"
            break
        fi

        if [[ "$status" == "unauthenticated" ]]; then
            if [[ "$INTERACTIVE" != true ]]; then
                log_error "Bitwarden CLI is not logged in (status: unauthenticated)."
                log_info "Run './$SCRIPT_NAME -i' for interactive setup, or authenticate via 'bw config server <url> && bw login'."
                exit 1
            fi

            log_header "BITWARDEN / VAULTWARDEN CLI AUTHENTICATION"

            if [[ -z "$SERVER_URL" ]]; then
                local default_srv="$DETECTED_SERVER_HINT"
                if [[ -z "$default_srv" ]]; then
                    default_srv="$(detect_vaultwarden_domain_hint)"
                fi
                if [[ -z "$default_srv" && -n "$norm_current" ]]; then
                    default_srv="$norm_current"
                fi

                flush_tty_input
                if [[ -n "$default_srv" ]]; then
                    printf "  Vaultwarden Server URL [${CYAN}%s${RESET}]: " "$default_srv" >&2
                else
                    printf "  Vaultwarden Server URL (e.g. https://vault.example.com): " >&2
                fi
                local input_srv=""
                read_tty_line input_srv
                input_srv="$(trim_whitespace "$input_srv")"
                input_srv="${input_srv:-$default_srv}"
                input_srv="$(normalize_server_url "$input_srv")"

                if [[ -z "$input_srv" ]]; then
                    log_error "A valid Vaultwarden / Bitwarden Server URL is required."
                    continue
                fi

                if ! run_bw_capture config server "$input_srv" --nointeraction; then
                    log_error "Failed to configure server '$input_srv':"
                    print_bw_error_details
                    continue
                fi
                SERVER_URL="$input_srv"
                log_success "Configured server: $input_srv"
            fi

            flush_tty_input
            printf "\n  ${BOLD}Login Method:${RESET}\n" >&2
            printf "    [1] Email & Master Password (supports 2FA) [Default]\n" >&2
            printf "    [2] Personal API Key (client_id & client_secret)\n" >&2
            printf "    [u] Change Server URL\n" >&2
            printf "    [q] Quit\n" >&2
            printf "  Selection [1-2, u, q]: " >&2

            local auth_method=""
            read_tty_line auth_method
            auth_method="$(trim_whitespace "$auth_method")"
            auth_method="${auth_method:-1}"

            case "$auth_method" in
                1)
                    printf "  Email address: " >&2
                    local bw_email=""
                    read_tty_line bw_email
                    bw_email="$(trim_whitespace "$bw_email")"
                    if [[ -z "$bw_email" ]]; then
                        log_error "Email address cannot be empty."
                        continue
                    fi

                    printf "  Master Password: " >&2
                    local bw_pw=""
                    read_tty_secret bw_pw
                    if [[ -z "$bw_pw" ]]; then
                        log_error "Master Password cannot be empty."
                        continue
                    fi

                    if [[ -t 0 && -r /dev/tty && -w /dev/tty ]]; then
                        log_info "Authenticating with server (if prompted, enter your 2FA / verification code)..."
                        local interactive_rc=0
                        BW_PASSWORD="$bw_pw" run_bw_exec --tty login "$bw_email" --passwordenv BW_PASSWORD </dev/tty >/dev/tty 2>/dev/tty || interactive_rc=$?
                        if [[ $interactive_rc -eq 0 ]]; then
                            if BW_PASSWORD="$bw_pw" run_bw_capture unlock --passwordenv BW_PASSWORD --nointeraction --raw && [[ -n "$CAPTURED_STDOUT" ]]; then
                                BW_SESSION="$CAPTURED_STDOUT"
                                export BW_SESSION
                                unset BW_PASSWORD bw_pw
                                log_success "Logged in and captured active vault session."
                                continue
                            fi
                            unset BW_PASSWORD bw_pw
                            log_error "Login succeeded, but automatic session unlock failed:"
                            print_bw_error_details
                            continue
                        fi
                        unset BW_PASSWORD bw_pw
                        log_error "Login did not complete."
                        log_info "Tip: If your account uses Passkey / FIDO2 WebAuthn-only 2FA (unsupported by CLI), choose [2] Personal API Key."
                        continue
                    fi

                    if BW_PASSWORD="$bw_pw" run_bw_capture login "$bw_email" --passwordenv BW_PASSWORD --nointeraction --raw && [[ -n "$CAPTURED_STDOUT" ]]; then
                        BW_SESSION="$CAPTURED_STDOUT"
                        export BW_SESSION
                        unset BW_PASSWORD bw_pw
                        log_success "Logged in and unlocked vault."
                        continue
                    fi

                    unset BW_PASSWORD bw_pw
                    log_error "Login failed:"
                    print_bw_error_details
                    ;;
                2)
                    printf "  Client ID (e.g. user.xxxx...): " >&2
                    local bw_cid=""
                    read_tty_line bw_cid
                    bw_cid="$(trim_whitespace "$bw_cid")"
                    printf "  Client Secret: " >&2
                    local bw_csecret=""
                    read_tty_secret bw_csecret

                    if [[ -z "$bw_cid" || -z "$bw_csecret" ]]; then
                        unset bw_cid bw_csecret
                        log_error "Both Client ID and Client Secret are required."
                        continue
                    fi

                    if BW_CLIENTID="$bw_cid" BW_CLIENTSECRET="$bw_csecret" run_bw_capture login --apikey --nointeraction; then
                        unset bw_cid bw_csecret
                        log_success "API key authenticated. Proceeding to unlock vault..."
                    else
                        unset bw_cid bw_csecret
                        log_error "API key login failed:"
                        print_bw_error_details
                    fi
                    ;;
                u|U)
                    SERVER_URL=""
                    ;;
                q|Q)
                    log_info "Cancelled authentication."
                    exit 0
                    ;;
                *)
                    log_error "Invalid selection: $auth_method"
                    ;;
            esac
            continue
        fi

        if [[ "$status" == "locked" ]]; then
            if [[ "$INTERACTIVE" != true ]]; then
                log_error "Vault is locked (${current_email:-account} @ ${current_server:-server})."
                log_info "Run with '-i' to unlock interactively, or run: export BW_SESSION=\"\$(bw unlock --raw)\""
                exit 1
            fi

            log_info "Vault is locked for ${BOLD}${current_email:-account}${RESET} (${DIM}${current_server:-server}${RESET})"
            printf "  Master Password (press Enter for account/server options): " >&2
            local bw_pw=""
            read_tty_secret bw_pw

            if [[ -z "$bw_pw" ]]; then
                flush_tty_input
                printf "  Options: [u] Unlock  [l] Logout / Switch account or server  [q] Quit: " >&2
                local lock_opt=""
                read_tty_line lock_opt
                lock_opt="$(trim_whitespace "$lock_opt")"
                case "$lock_opt" in
                    l|L)
                        run_bw_capture logout --nointeraction || true
                        BW_SESSION=""
                        export BW_SESSION
                        SERVER_URL=""
                        log_info "Logged out of previous session."
                        ;;
                    q|Q)
                        exit 0
                        ;;
                esac
                continue
            fi

            if BW_PASSWORD="$bw_pw" run_bw_capture unlock --passwordenv BW_PASSWORD --nointeraction --raw && [[ -n "$CAPTURED_STDOUT" ]]; then
                BW_SESSION="$CAPTURED_STDOUT"
                export BW_SESSION
                unset bw_pw
                log_success "Vault unlocked."
            else
                unset bw_pw
                log_error "Unlock failed:"
                print_bw_error_details
            fi
            continue
        fi

        log_error "Unrecognized Bitwarden CLI status: '$status'"
        exit 1
    done

    log_info "Synchronizing vault with server..."
    if ! run_bw_capture sync --nointeraction; then
        log_error "Failed to synchronize vault:"
        print_bw_error_details
        exit 1
    fi
    log_success "Vault synchronized (${CONNECTED_ACCOUNT})."
}

prepare_target_environment() {
    if [[ "$EXEC_TARGET" == "file" ]]; then
        if [[ ! -f "$INPUT_FILE" ]]; then
            log_error "File not found: $INPUT_FILE"
            exit 1
        fi
        return 0
    elif [[ "$EXEC_TARGET" == "mock" ]]; then
        if [[ ! -f "$MOCK_BW_DIR/items.json" ]]; then
            if [[ -f "$MOCK_BW_DIR/mock_vault/items.json" ]]; then
                MOCK_BW_DIR="$MOCK_BW_DIR/mock_vault"
            else
                log_error "Mock vault state not found at: $MOCK_BW_DIR/items.json"
                exit 1
            fi
        fi
        return 0
    elif [[ "$EXEC_TARGET" == "docker" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            log_error "'docker' command not found on host."
            exit 1
        fi
        local is_running=""
        is_running="$(docker inspect -f '{{.State.Running}}' "$DOCKER_CONTAINER" 2>/dev/null || true)"
        if [[ "$is_running" != "true" ]]; then
            log_error "Docker container '$DOCKER_CONTAINER' is not running or does not exist."
            exit 1
        fi
        if ! docker exec "$DOCKER_CONTAINER" sh -c 'command -v bw >/dev/null 2>&1' </dev/null 2>/dev/null; then
            local c_image=""
            c_image="$(docker inspect -f '{{.Config.Image}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")"
            DETECTED_SERVER_HINT="$(detect_vaultwarden_domain_hint)"
            log_warn "Container '$DOCKER_CONTAINER' (image: $c_image) does not contain the Bitwarden CLI ('bw')."
            log_info "Note: 'vaultwarden/server' containers store encrypted ciphertext only and cannot decrypt items directly."
            if [[ "$INTERACTIVE" == true ]]; then
                if prompt_yes_default "Switch to local standalone Bitwarden CLI ($LOCAL_BW_BIN) instead?"; then
                    EXEC_TARGET="local"
                else
                    exit 1
                fi
            else
                log_error "Omit '--docker $DOCKER_CONTAINER' and run './$SCRIPT_NAME -i' to use the local standalone Bitwarden CLI."
                exit 1
            fi
        fi
    fi

    if [[ "$EXEC_TARGET" == "local" ]]; then
        ensure_bw_cli
    fi

    if [[ "$EXEC_TARGET" == "local" || "$EXEC_TARGET" == "docker" ]]; then
        ensure_bw_authenticated
    fi
}

fetch_vault_json() {
    if [[ "$EXEC_TARGET" == "file" ]]; then
        if [[ ! -f "$INPUT_FILE" ]]; then
            log_error "File not found: $INPUT_FILE"
            return 1
        fi
        cat "$INPUT_FILE"
    elif [[ "$EXEC_TARGET" == "mock" ]]; then
        if [[ ! -f "$MOCK_BW_DIR/items.json" ]]; then
            if [[ -f "$MOCK_BW_DIR/mock_vault/items.json" ]]; then
                MOCK_BW_DIR="$MOCK_BW_DIR/mock_vault"
            else
                log_error "Mock vault state not found at: $MOCK_BW_DIR/items.json"
                return 1
            fi
        fi
        cat "$MOCK_BW_DIR/items.json"
    elif [[ "$EXEC_TARGET" == "docker" || "$EXEC_TARGET" == "local" ]]; then
        if ! run_bw_capture list items --nointeraction; then
            log_error "Failed to retrieve vault items from Bitwarden CLI:"
            print_bw_error_details
            return 1
        fi
        if ! printf '%s\n' "$CAPTURED_STDOUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
            log_error "Bitwarden CLI returned unexpected non-JSON-array output:"
            print_bw_error_details
            return 1
        fi
        printf '%s\n' "$CAPTURED_STDOUT"
    fi
}

bw_update_item() {
    local item_json="$1"
    local item_idx="${2:-}"
    local item_id item_name
    item_id="$(printf '%s\n' "$item_json" | jq -r '.id // empty')"
    item_name="$(printf '%s\n' "$item_json" | jq -r '.name // "<empty>"')"

    if [[ "$VERBOSE" == true ]]; then
        log_info "[VERBOSE] Updating item ${item_id:-no-id} ('$item_name')..."
    fi

    if [[ "$EXEC_TARGET" == "mock" ]]; then
        jq --arg id "$item_id" --arg idx "$item_idx" --argjson updated "$item_json" '
          if ($id != "") then
            map(if .id == $id then $updated else . end)
          elif ($idx != "") then
            to_entries | map(if .key == ($idx | tonumber) then $updated else .value end)
          else
            .
          end
        ' "$MOCK_BW_DIR/items.json" > "$MOCK_BW_DIR/items.json.tmp"
        mv "$MOCK_BW_DIR/items.json.tmp" "$MOCK_BW_DIR/items.json"
    elif [[ -n "$OUTPUT_FILE" ]]; then
        WORKING_VAULT_JSON="$(printf '%s\n' "$WORKING_VAULT_JSON" | jq \
          --arg id "$item_id" --arg idx "$item_idx" --argjson updated "$item_json" '
          if ($id != "") then
            map(if .id == $id then $updated else . end)
          elif ($idx != "") then
            to_entries | map(if .key == ($idx | tonumber) then $updated else .value end)
          else
            .
          end
        ')"
        printf '%s\n' "$WORKING_VAULT_JSON" > "$OUTPUT_FILE"
    elif [[ "$EXEC_TARGET" == "docker" || "$EXEC_TARGET" == "local" ]]; then
        if ! run_bw_stdin "$item_json" encode; then
            log_error "Failed to encode item '${item_id:-no-id}':"
            print_bw_error_details
            return 1
        fi
        local encoded_item="$CAPTURED_STDOUT"

        if ! run_bw_stdin "$encoded_item" edit item "$item_id" --nointeraction; then
            log_error "Failed to update item '${item_id:-no-id}':"
            print_bw_error_details
            return 1
        fi
    else
        log_error "Input '--file' mode is read-only. Specify '--output <file>' to save changes."
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        log_success "[VERBOSE] Item ${item_id:-no-id} ('$item_name') updated."
    fi
    return 0
}

bw_delete_single_item() {
    local id="$1"
    local label="${2:-}"
    if [[ "$VERBOSE" == true ]]; then
        log_info "[VERBOSE] Deleting redundant item $id${label:+ ('$label')}..."
    fi
    if [[ "$EXEC_TARGET" == "mock" ]]; then
        jq --arg item_id "$id" 'map(select(.id != $item_id))' "$MOCK_BW_DIR/items.json" > "$MOCK_BW_DIR/items.json.tmp"
        mv "$MOCK_BW_DIR/items.json.tmp" "$MOCK_BW_DIR/items.json"
    elif [[ -n "$OUTPUT_FILE" ]]; then
        WORKING_VAULT_JSON="$(printf '%s\n' "$WORKING_VAULT_JSON" | jq --arg item_id "$id" 'map(select(.id != $item_id))')"
        printf '%s\n' "$WORKING_VAULT_JSON" > "$OUTPUT_FILE"
    elif [[ "$EXEC_TARGET" == "docker" || "$EXEC_TARGET" == "local" ]]; then
        if ! run_bw_capture delete item "$id" --nointeraction; then
            log_error "Failed to delete item '$id':"
            print_bw_error_details
            return 1
        fi
    else
        log_error "Input '--file' mode is read-only. Specify '--output <file>' to save changes."
        return 1
    fi
    if [[ "$VERBOSE" == true ]]; then
        log_success "[VERBOSE] Redundant item $id deleted."
    fi
    return 0
}

# Unified item-update executor: changing one vs changing all runs the exact same
# single-item update path, either asking per item (-i -v) or iterating over all.
apply_modified_items_plan() {
    local raw_json="$1"
    local transformed_json="$2"
    local modified_count="$3"
    local card_fn="$4"
    local batch_label="$5"
    local item_prompt_noun="$6"
    local mock_noun="${7:-item(s)}"

    local preview_only=false
    local ask_each=false
    local prev_verbose="$VERBOSE"
    if [[ "$INTERACTIVE" == true ]]; then
        if [[ "$VERBOSE" == true ]]; then
            ask_each=true
        else
            if ! prompt_confirmation "$batch_label"; then
                return 0
            fi
            if [[ "$CONFIRM_ACTION" == "verify" ]]; then
                ask_each=true
            fi
        fi
    elif [[ "$MODE" == "preview" ]]; then
        preview_only=true
    fi

    if [[ "$preview_only" != true && "$EXEC_TARGET" == "file" && -z "$OUTPUT_FILE" ]]; then
        log_error "Input '--file' mode is read-only. Re-run with '--output <file>' to save changes."
        return 1
    fi

    if [[ "$ask_each" == true && "$VERBOSE" != true ]]; then
        VERBOSE=true
        log_info "Switched to one-by-one verify mode for this operation."
    fi

    if [[ "$preview_only" == true && "$VERBOSE" != true ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No changes written. Run with -i or --apply to execute."
        return 0
    fi

    WORKING_VAULT_JSON="$raw_json"
    local mod_items curr=0 ok_count=0 skip_count=0 fail_count_upd=0 raw_item
    mod_items=$(echo "$transformed_json" | jq -c '.[] | select(._modified == true)')

    while IFS= read -r -u 3 raw_item; do
        [[ -z "$raw_item" ]] && continue
        curr=$((curr + 1))

        if [[ "$VERBOSE" == true ]]; then
            "$card_fn" "$curr" "$modified_count" "$raw_item"
        else
            render_progress "$curr" "$modified_count" "Updating items"
        fi

        [[ "$preview_only" == true ]] && continue

        if [[ "$ask_each" == true ]]; then
            prompt_verbose_item_decision "$item_prompt_noun [$curr/$modified_count]?"
            case "$VERBOSE_DECISION" in
                no)
                    skip_count=$((skip_count + 1))
                    log_info "Skipped item [$curr/$modified_count]."
                    continue
                    ;;
                quit)
                    local rem=$((modified_count - curr + 1))
                    log_warn "Cancelled remaining $rem item(s)."
                    break
                    ;;
                all)
                    ask_each=false
                    local rem_apply=$((modified_count - curr + 1))
                    log_info "Applying this and remaining item(s) ($rem_apply item(s)) without further prompts..."
                    ;;
            esac
        fi

        local item_idx clean_item
        item_idx=$(printf '%s\n' "$raw_item" | jq -r '._idx // empty')
        clean_item=$(printf '%s\n' "$raw_item" | jq -c 'del(._idx, ._modified, ._added_uris, ._old_uris, ._old_name, ._extra_uri_candidate, ._candidate_uris)')

        if bw_update_item "$clean_item" "$item_idx"; then
            ok_count=$((ok_count + 1))
        else
            fail_count_upd=$((fail_count_upd + 1))
        fi
    done 3<<< "$mod_items"

    if [[ "$preview_only" == true ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No changes written. Run with -i or --apply to execute."
        return 0
    fi

    local skip_note=""
    [[ $skip_count -gt 0 ]] && skip_note=" ($skip_count skipped)"

    if [[ "$EXEC_TARGET" == "mock" ]]; then
        if [[ $ok_count -eq 0 && $fail_count_upd -eq 0 ]]; then
            log_warn "No items were modified (0 updated${skip_note})."
        elif [[ $fail_count_upd -eq 0 ]]; then
            log_success "[MOCK BW] $ok_count $mock_noun updated in $MOCK_BW_DIR/items.json${skip_note}."
        else
            log_warn "[MOCK BW] $ok_count $mock_noun updated, $fail_count_upd failed${skip_note}."
        fi
    elif [[ -n "$OUTPUT_FILE" ]]; then
        if [[ $ok_count -eq 0 && $fail_count_upd -eq 0 ]]; then
            log_warn "No items were modified (0 updated${skip_note})."
        elif [[ $fail_count_upd -eq 0 ]]; then
            log_success "$ok_count updated item(s) saved to: $OUTPUT_FILE${skip_note}."
        else
            log_warn "$ok_count item(s) saved to $OUTPUT_FILE, $fail_count_upd failed${skip_note}."
        fi
    else
        if [[ $ok_count -eq 0 && $fail_count_upd -eq 0 ]]; then
            log_warn "No items were modified (0 updated${skip_note})."
        elif [[ $fail_count_upd -eq 0 ]]; then
            log_success "$ok_count item(s) successfully updated${skip_note}."
        else
            log_warn "$ok_count item(s) updated, $fail_count_upd failed${skip_note}."
        fi
    fi

    VERBOSE="$prev_verbose"
    [[ $fail_count_upd -gt 0 ]] && return 1
    return 0
}

# --- VERBOSE DIFF PRESENTERS (Secrets Masked) ---
print_verbose_uri_diff_card() {
    local idx="$1"
    local total="$2"
    local item_json="$3"

    printf "\n" >&2
    printf '%s\n' "$item_json" | jq -r \
      --arg idx "$idx" \
      --arg total "$total" \
      --arg bold "$BOLD" \
      --arg cyan "$CYAN" \
      --arg green "$GREEN" \
      --arg dim "$DIM" \
      --arg reset "$RESET" '
      def mask_pw(p):
        if (p // "") == "" then "<empty>" else "******** (set, len \(p | length))" end;
      def fmt_fields(f):
        if (f // [] | length) == 0 then ["<none>"]
        else [ f[] | if .type == 1 then "\(.name // "unnamed") = ******** (hidden)" else "\(.name // "unnamed") = \(.value // "")" end ]
        end;
      def fmt_notes(n; pad):
        if (n // "") == "" then "<empty>"
        else (n | split("\n") | join("\n" + pad))
        end;

      ($cyan + "┌─ [" + $idx + "/" + $total + "] " + $bold + "UPDATE ITEM: Migrate KeePass Web Match URIs" + $reset + $cyan + " ─────────────────────" + $reset),
      ($cyan + "│" + $reset + " Item ID:   " + $bold + (.id // "no-id") + $reset),
      ($cyan + "│" + $reset + " Name:      " + (.name // "<empty>")),
      ($cyan + "│" + $reset + " Username:  " + (.login.username // "<empty>")),
      ($cyan + "│" + $reset + " Password:  " + mask_pw(.login.password)),
      (if (.login.totp // "") != "" then ($cyan + "│" + $reset + " TOTP:      ******** (configured)") else empty end),
      ($cyan + "│" + $reset + " Notes:     " + fmt_notes(.notes; $cyan + "│" + $reset + "            ")),
      (fmt_fields(.fields) | to_entries[] |
        if .key == 0 then ($cyan + "│" + $reset + " Fields:    " + .value)
        else ($cyan + "│" + $reset + "            " + .value)
        end),
      ($cyan + "│" + $reset + " " + $bold + "Changes to login.uris:" + $reset),
      (if ((._old_uris // []) | length) == 0 then
        ($cyan + "│" + $reset + "   " + $dim + "= Existing URI: <none>" + $reset)
       else
        (._old_uris[] | ($cyan + "│" + $reset + "   " + $dim + "= Existing URI: " + . + $reset))
       end),
      ((._added_uris // [])[] | ($cyan + "│" + $reset + "   " + $green + "+ Added URI:    " + . + " (match: default)" + $reset)),
      ($cyan + "└──────────────────────────────────────────────────────────────────────────────" + $reset)
    ' >&2
}

print_verbose_name_diff_card() {
    local idx="$1"
    local total="$2"
    local item_json="$3"

    printf "\n" >&2
    printf '%s\n' "$item_json" | jq -r \
      --arg idx "$idx" \
      --arg total "$total" \
      --arg bold "$BOLD" \
      --arg cyan "$CYAN" \
      --arg yellow "$YELLOW" \
      --arg green "$GREEN" \
      --arg reset "$RESET" '
      def mask_pw(p):
        if (p // "") == "" then "<empty>" else "******** (set, len \(p | length))" end;
      def fmt_fields(f):
        if (f // [] | length) == 0 then ["<none>"]
        else [ f[] | if .type == 1 then "\(.name // "unnamed") = ******** (hidden)" else "\(.name // "unnamed") = \(.value // "")" end ]
        end;
      def fmt_uris(u):
        if (u // [] | length) == 0 then ["<none>"]
        else [ u[] | .uri // "" ]
        end;
      def fmt_notes(n; pad):
        if (n // "") == "" then "<empty>"
        else (n | split("\n") | join("\n" + pad))
        end;

      ($cyan + "┌─ [" + $idx + "/" + $total + "] " + $bold + "UPDATE ITEM: Set Entry Name" + $reset + $cyan + " ────────────────────────────────────" + $reset),
      ($cyan + "│" + $reset + " Item ID:   " + $bold + (.id // "no-id") + $reset),
      ($cyan + "│" + $reset + " Username:  " + (.login.username // "<empty>")),
      ($cyan + "│" + $reset + " Password:  " + mask_pw(.login.password)),
      (fmt_uris(.login.uris) | to_entries[] |
        if .key == 0 then ($cyan + "│" + $reset + " URIs:      " + .value)
        else ($cyan + "│" + $reset + "            " + .value)
        end),
      ($cyan + "│" + $reset + " Notes:     " + fmt_notes(.notes; $cyan + "│" + $reset + "            ")),
      (fmt_fields(.fields) | to_entries[] |
        if .key == 0 then ($cyan + "│" + $reset + " Fields:    " + .value)
        else ($cyan + "│" + $reset + "            " + .value)
        end),
      ($cyan + "│" + $reset + " " + $bold + "Changes to name:" + $reset),
      ($cyan + "│" + $reset + "   " + $yellow + "- Before: " + (._old_name // "<empty>") + $reset),
      ($cyan + "│" + $reset + "   " + $green + "+ After:  " + (.name // "<empty>") + $reset),
      ($cyan + "└──────────────────────────────────────────────────────────────────────────────" + $reset)
    ' >&2
}

print_verbose_merge_cluster_card() {
    local idx="$1"
    local total="$2"
    local cluster_json="$3"

    printf "\n" >&2
    printf '%s\n' "$cluster_json" | jq -r \
      --arg idx "$idx" \
      --arg total "$total" \
      --arg bold "$BOLD" \
      --arg cyan "$CYAN" \
      --arg yellow "$YELLOW" \
      --arg green "$GREEN" \
      --arg red "$RED" \
      --arg dim "$DIM" \
      --arg reset "$RESET" '
      def mask_pw(p):
        if (p // "") == "" then "<empty>" else "******** (set, len \(p | length))" end;
      def fmt_field_inline(f):
        if (f // [] | length) == 0 then "<none>"
        else ([ f[] | if .type == 1 then "\(.name // "unnamed")=********(hidden)" else "\(.name // "unnamed")=\(.value // "")" end ] | join(", "))
        end;
      def fmt_uris_inline(u):
        if (u // [] | length) == 0 then "<none>"
        else ([ u[] | .uri // "" ] | join(", "))
        end;
      def fmt_pk(item):
        if (item.login.fido2Credentials // [] | length) > 0 then
          "🔒 \(item.login.fido2Credentials | length) passkey(s) protected"
        else "<none>" end;
      def fmt_totp(item):
        if (item.login.totp // "") != "" then "******** (configured)" else "<none>" end;
      def fmt_notes(n; pad):
        if (n // "") == "" then "<empty>"
        else (n | split("\n") | join("\n" + pad))
        end;

      if .status == "CONFLICT_MULTIPLE_PASSKEYS" then
        ($yellow + "┌─ [Conflict " + $idx + "/" + $total + "] " + $bold + "SKIPPED — MULTIPLE PASSKEYS PROTECTED" + $reset + $yellow + " ──────────────────" + $reset),
        ($yellow + "│" + $reset + " Reason:    " + (.reason // "Multiple FIDO2 passkeys")),
        ((.conflict_items // [])[] |
          ($yellow + "│" + $reset + " 🔒 Protected ID: " + $bold + (.id // "no-id") + $reset + " | Name: " + (.name // "<empty>") + " | User: " + (.login.username // "<empty>") + " | " + fmt_pk(.))
        ),
        ($yellow + "└──────────────────────────────────────────────────────────────────────────────" + $reset)
      elif .status == "CONFLICT_MULTIPLE_TOTP" then
        ($yellow + "┌─ [Conflict " + $idx + "/" + $total + "] " + $bold + "SKIPPED — DIFFERENT 2FA/TOTP SECRETS PROTECTED" + $reset + $yellow + " ───────────" + $reset),
        ($yellow + "│" + $reset + " Reason:    " + (.reason // "Multiple different 2FA TOTP secrets")),
        ((.conflict_items // [])[] |
          ($yellow + "│" + $reset + " 🔒 Protected ID: " + $bold + (.id // "no-id") + $reset + " | Name: " + (.name // "<empty>") + " | User: " + (.login.username // "<empty>") + " | TOTP: " + fmt_totp(.))
        ),
        ($yellow + "└──────────────────────────────────────────────────────────────────────────────" + $reset)
      else
        .original_canonical as $orig |
        .merged_item as $merged |
        ($cyan + "┌─ [Cluster " + $idx + "/" + $total + "] " + $bold + "MERGE & DELETE DUPLICATE(S)" + $reset + $cyan + " ──────────────────────────────" + $reset),
        ($cyan + "│" + $reset + " " + $bold + $green + "CANONICAL ITEM (KEPT):" + $reset),
        ($cyan + "│" + $reset + "   Item ID:   " + $bold + ($orig.id // "no-id") + $reset),
        ($cyan + "│" + $reset + "   Name:      " + ($orig.name // "<empty>")),
        ($cyan + "│" + $reset + "   Username:  " + ($orig.login.username // "<empty>")),
        ($cyan + "│" + $reset + "   Password:  " + mask_pw($orig.login.password)),
        ($cyan + "│" + $reset + "   TOTP:      " + fmt_totp($orig)),
        ($cyan + "│" + $reset + "   Passkeys:  " + fmt_pk($orig)),
        ($cyan + "│" + $reset + "   Dates:     Created " + ($orig.creationDate // "N/A") + " | Revised " + ($orig.revisionDate // "N/A")),
        (if .canonical_changed then
          ($cyan + "│" + $reset + "   Action:    " + $yellow + "UPDATE CANONICAL ITEM (consolidating attributes from duplicate(s))" + $reset),
          (if .added_totp then
            ($cyan + "│" + $reset + "   " + $green + "+ Merged TOTP:    ******** (2FA secret preserved from duplicate)" + $reset)
           else empty end),
          (if (.added_notes // "") != "" then
            ($cyan + "│" + $reset + "   " + $yellow + "- Notes (before): " + fmt_notes($orig.notes; $cyan + "│" + $reset + "                     ") + $reset),
            ($cyan + "│" + $reset + "   " + $green + "+ Notes (after):  " + fmt_notes($merged.notes; $cyan + "│" + $reset + "                     ") + $reset)
           else empty end),
          ((.added_fields // [])[] |
            ($cyan + "│" + $reset + "   " + $green + "+ Merged Field:   " + (if .type == 1 then "\(.name // "unnamed") = ******** (hidden)" else "\(.name // "unnamed") = \(.value // "")" end) + $reset)
          ),
          ((.added_uris // [])[] |
            ($cyan + "│" + $reset + "   " + $green + "+ Merged URI:     " + . + $reset)
          )
         else
          ($cyan + "│" + $reset + "   Action:    " + $dim + "KEEP AS-IS (no edit needed; canonical already contains all attributes)" + $reset),
          ($cyan + "│" + $reset + "   URIs:      " + fmt_uris_inline($orig.login.uris)),
          ($cyan + "│" + $reset + "   Fields:    " + fmt_field_inline($orig.fields)),
          ($cyan + "│" + $reset + "   Notes:     " + fmt_notes($orig.notes; $cyan + "│" + $reset + "              "))
         end),
        ($cyan + "│" + $reset),
        ($cyan + "│" + $reset + " " + $bold + $red + "REDUNDANT DUPLICATE(S) TO DELETE (\(.redundant_items | length) item(s)):" + $reset),
        ((.redundant_items // [])[] |
          ($cyan + "│" + $reset + "   " + $red + "✖ DELETE ID: " + $bold + (.id // "no-id") + $reset),
          ($cyan + "│" + $reset + "     Name:      " + (.name // "<empty>") + " | User: " + (.login.username // "<empty>") + " | Password: " + mask_pw(.login.password)),
          ($cyan + "│" + $reset + "     Dates:     Created " + (.creationDate // "N/A") + " | Revised " + (.revisionDate // "N/A")),
          ($cyan + "│" + $reset + "     URIs:      " + fmt_uris_inline(.login.uris)),
          ($cyan + "│" + $reset + "     Fields:    " + fmt_field_inline(.fields)),
          ($cyan + "│" + $reset + "     Notes:     " + fmt_notes(.notes; $cyan + "│" + $reset + "                "))
        ),
        ($cyan + "└──────────────────────────────────────────────────────────────────────────────" + $reset)
      end
    ' >&2
}

# --- OPERATION 1: Fix URIs (KeePass Cleanup) ---
op_fix_uris() {
    local raw_json="$1"
    log_header "OPERATION: Fix KeePass Web Match URIs"

    local total_items
    total_items=$(echo "$raw_json" | jq 'length')
    render_progress "$total_items" "$total_items" "Scanning items"

    local transformed_json
    transformed_json=$(echo "$raw_json" | jq --argjson include_existing "$INCLUDE_EXISTING_URIS" '
      def extract_urls_from_text:
        [scan("(https?://[a-zA-Z0-9./?=_-]+)")] | map({uri: .[0], match: 0});
      def unique_uris:
        reduce .[] as $u ([]; if any(.[]; .uri == $u.uri) then . else . + [$u] end);

      to_entries | map(
        .key as $idx | .value |
        if .type == 1 then
          . as $item |
          ($item.notes // "" | extract_urls_from_text) as $note_urls |
          ([$item.fields[]? | select(.type == 0 and (.value | test("^https?://")))? | {uri: .value, match: 0}]) as $field_urls |
          ($note_urls + $field_urls) as $found_urls |
          ($item.login.uris // []) as $existing_uris |
          ([$existing_uris[] | select(((.uri // "") | gsub("^\\s+|\\s+$"; "")) != "")]) as $nonempty_uris |
          (($nonempty_uris | length) == 0) as $has_no_uri |
          ([$found_urls[] | select(.uri as $u | ($nonempty_uris | map(.uri) | index($u)) == null)] | unique_uris) as $new_uris |

          if ($new_uris | length) > 0 then
            if $has_no_uri or $include_existing then
              ._idx = $idx |
              ._old_uris = ($nonempty_uris | map(.uri)) |
              .login.uris = ($nonempty_uris + $new_uris) |
              ._modified = true |
              ._added_uris = ($new_uris | map(.uri))
            else
              ._idx = $idx |
              ._old_uris = ($nonempty_uris | map(.uri)) |
              ._candidate_uris = ($nonempty_uris + $new_uris) |
              ._added_uris = ($new_uris | map(.uri)) |
              ._extra_uri_candidate = true
            end
          else
            .
          end
        else
          .
        end
      )
    ')

    local modified_count existing_extra_count
    modified_count=$(echo "$transformed_json" | jq '[.[] | select(._modified == true)] | length')
    existing_extra_count=$(echo "$transformed_json" | jq '[.[] | select(._extra_uri_candidate == true)] | length')

    printf "\n" >&2
    log_info "Vault size: $total_items items"

    if [[ "$INTERACTIVE" == true && "$INCLUDE_EXISTING_URIS" != true && "$existing_extra_count" -gt 0 ]]; then
        flush_tty_input
        printf "\n${BOLD}${YELLOW}Scope selection:${RESET}\n" >&2
        printf "  Found ${BOLD}%d${RESET} item(s) without any URL requiring migration.\n" "$modified_count" >&2
        printf "  Also found ${BOLD}%d${RESET} item(s) that already have a URL, with additional URL(s) in notes/fields.\n" "$existing_extra_count" >&2
        printf "  [1] Only items without any URL (%d item(s)) [Default]\n" "$modified_count" >&2
        printf "  [2] Include items that already have URIs (%d item(s) total)\n" "$((modified_count + existing_extra_count))" >&2
        printf "  Selection [1-2] (Default: 1): " >&2
        local scope_choice=""
        read_tty_line scope_choice
        scope_choice="$(trim_whitespace "$scope_choice")"
        case "$scope_choice" in
            2)
                transformed_json=$(echo "$transformed_json" | jq '
                  map(
                    if ._extra_uri_candidate == true then
                      .login.uris = ._candidate_uris |
                      ._modified = true |
                      del(._extra_uri_candidate, ._candidate_uris)
                    else
                      .
                    end
                  )
                ')
                modified_count=$(echo "$transformed_json" | jq '[.[] | select(._modified == true)] | length')
                existing_extra_count=0
                log_info "Included items that already have URIs (total to update: $modified_count)."
                ;;
            *)
                log_info "Keeping items that already have URIs unchanged."
                ;;
        esac
    fi

    log_info "Items requiring URI migration: ${BOLD}$modified_count${RESET}"
    if [[ "$existing_extra_count" -gt 0 ]]; then
        log_info "Items already having URIs with extra links in notes/fields: ${BOLD}$existing_extra_count${RESET} (skipped by default; use --all-uris to include)"
    fi

    if [[ "$modified_count" -gt 0 ]]; then
        printf "\n${BOLD}%-36s │ %-25s │ %s${RESET}\n" "ITEM ID" "NAME" "MIGRATED URIS"
        printf "%s\n" "─────────────────────────────────────┼───────────────────────────┼─────────────────────────────────────"
        echo "$transformed_json" | jq -r '
          .[] | select(._modified == true) |
          "\(.id // "no-id")|\((.name // "N/A")[0:25])|\((._added_uris // []) | join(", "))"
        ' | awk -F '|' -v c1="$CYAN" -v r="$RESET" '{printf "%-36s │ %-25s │ " c1 "%s" r "\n", $1, $2, $3}'
    fi

    if [[ "$modified_count" -eq 0 ]]; then
        if [[ "$existing_extra_count" -gt 0 ]]; then
            log_success "All entries without a URL are clean ($existing_extra_count item(s) with existing URIs were skipped)."
        else
            log_success "All entries already have clean web match URIs. Nothing to do."
        fi
        return 0
    fi

    apply_modified_items_plan \
        "$raw_json" \
        "$transformed_json" \
        "$modified_count" \
        "print_verbose_uri_diff_card" \
        "Update $modified_count item(s)" \
        "Apply URI migration" \
        "item(s)"
}

# --- OPERATION 2: Fix Missing Names ---
op_fix_names() {
    local raw_json="$1"
    log_header "OPERATION: Generate Names for Unnamed Entries"

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

      to_entries | map(
        .key as $idx | .value |
        if .type == 1 then
          . as $item |
          ($item.login.uris[0].uri // "") as $uri |
          ($item.login.username // "") as $user |
          extract_domain($uri) as $dom |
          
          ($item.name // "" | gsub("^\\s+|\\s+$"; "")) as $trimmed_name |
          ($item.name == null or $trimmed_name == "" or $trimmed_name == "--") as $is_missing |
          
          if $is_missing and ($dom != "" or $user != "") then
            (if $dom != "" and $user != "" then
               "\($dom) (\($user))"
             elif $dom != "" then
               $dom
             else
               "Account (\($user))"
             end) as $generated_name |
            
            if $item.name != $generated_name then
              ._idx = $idx |
              ._old_name = (if $trimmed_name == "" then "<empty>" else $trimmed_name end) |
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
    log_info "Items without a name: ${BOLD}$modified_count${RESET}"

    if [[ "$modified_count" -gt 0 ]]; then
        printf "\n${BOLD}%-36s │ %-30s ➔ %-35s${RESET}\n" "ITEM ID" "CURRENT NAME" "PROPOSED DESCRIPTIVE NAME"
        printf "%s\n" "─────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────"
        echo "$transformed_json" | jq -r '
          .[] | select(._modified == true) |
          "\(.id // "no-id")|\(._old_name[0:30])|\(.name)"
        ' | awk -F '|' -v c1="$YELLOW" -v c2="$GREEN" -v r="$RESET" '{printf "%-36s │ " c1 "%-30s" r " ➔ " c2 "%s" r "\n", $1, $2, $3}'
    fi

    if [[ "$modified_count" -eq 0 ]]; then
        log_success "All entries already have a name. Nothing to do."
        return 0
    fi

    apply_modified_items_plan \
        "$raw_json" \
        "$transformed_json" \
        "$modified_count" \
        "print_verbose_name_diff_card" \
        "Rename $modified_count item(s)" \
        "Apply generated name" \
        "name(s)"
}

# --- DUPLICATE DETECTION ENGINES ---
read -r -d '' JQ_DOMAIN_PASSKEY_HELPERS << 'EOF' || true
def has_passkey(item):
  (item.login.fido2Credentials != null and (item.login.fido2Credentials | length) > 0);

def norm_passkeys(fido):
  ((fido // []) | sort_by(.credentialId // "", .rpId // "", .userHandle // ""));

def extract_main_domain(uri):
  if uri == null or uri == "" then ""
  else
    (uri | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $u |
    if ($u == "" or ($u | test("\\s"))) then ""
    elif (($u | test("^[a-z][a-z0-9+.-]*://")) and (($u | test("^https?://")) | not)) then ""
    else
      ($u | sub("^https?://"; "") | split("/")[0] | split("?")[0] | split("#")[0] | split("@")[-1]) as $authority |
      (if ($authority | startswith("[")) then
         ($authority | split("]")[0] | sub("^\\["; ""))
       else
         ($authority | split(":")[0])
       end | sub("^\\.+"; "") | sub("\\.+$"; "")) as $host |
      if ($host == "" or $host == "http" or $host == "https") then ""
      elif (($host | test("^[0-9]+(\\.[0-9]+){3}$")) or ($host | contains(":"))) then
        $host
      elif ($host | split(".") | any(. == "")) then
        ""
      else
        ($host | split(".")) as $parts |
        ($parts | length) as $len |
        if $len <= 2 then
          $host
        else
          ($parts[-2] + "." + $parts[-1]) as $last2 |
          if ([
            "co.uk","org.uk","me.uk","ac.uk","gov.uk","net.uk","ltd.uk","plc.uk","sch.uk","nhs.uk","mod.uk",
            "com.au","net.au","org.au","edu.au","gov.au","asn.au","id.au",
            "co.nz","net.nz","org.nz","govt.nz","ac.nz","school.nz",
            "co.jp","ne.jp","or.jp","ac.jp","ad.jp","ed.jp","go.jp","gr.jp","lg.jp",
            "com.br","net.br","org.br","gov.br","edu.br",
            "com.cn","net.cn","org.cn","gov.cn","edu.cn",
            "com.tw","org.tw","net.tw","idv.tw",
            "com.hk","org.hk","edu.hk","gov.hk",
            "co.kr","or.kr","ne.kr","go.kr",
            "co.za","org.za","gov.za",
            "co.in","net.in","org.in","gov.in","ac.in",
            "com.tr","net.tr","org.tr","gov.tr","bel.tr","k12.tr",
            "com.mx","org.mx","gob.mx","edu.mx",
            "com.ar","gov.ar","org.ar",
            "co.il","org.il","ac.il","gov.il",
            "co.at","or.at","gv.at","ac.at","priv.at",
            "com.pl","net.pl","org.pl","gov.pl","edu.pl",
            "com.es","nom.es","org.es","gob.es","edu.es",
            "com.sg","org.sg","gov.sg","edu.sg",
            "com.my","org.my","gov.my",
            "co.id","or.id","go.id","web.id","sch.id","ac.id",
            "com.ph","org.ph","gov.ph",
            "co.th","or.th","in.th","ac.th","go.th",
            "com.ua","org.ua","net.ua","gov.ua",
            "co.ke","eu.org",
            "com.co","org.co","net.co","gov.co","nom.co",
            "qc.ca","on.ca","bc.ca","ab.ca",
            "github.io","gitlab.io","bitbucket.io","pages.dev","workers.dev",
            "herokuapp.com","appspot.com","azurewebsites.net","cloudfront.net",
            "vercel.app","netlify.app","fly.dev","onrender.com","railway.app",
            "ddns.net","duckdns.org","dyndns.org","no-ip.org",
            "myfritz.net","synology.me","quickconnect.to"
          ] | index($last2)) != null then
            ($parts[-3:] | join("."))
          else
            ($parts[-2:] | join("."))
          end
        end
      end
    end
  end;

def item_main_domains(item):
  [ item.login.uris[]? | (.uri // "") | extract_main_domain(.) | select(. != "") ]
  | unique | sort;
EOF

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
    echo "$raw_json" | jq "${JQ_DOMAIN_PASSKEY_HELPERS}"'
      group_by({
        type: .type,
        name: .name,
        login: {
          username: .login.username,
          password: .login.password,
          totp: (.login.totp // ""),
          uris: (.login.uris // [] | map(.uri) | sort),
          has_passkey: has_passkey(.),
          passkeys: norm_passkeys(.login.fido2Credentials)
        },
        notes: .notes,
        fields: (.fields // [] | sort_by(.name))
      }) |
      map(select(length > 1)) |
      map(
        sort_by(if has_passkey(.) then 0 else 1 end) |
        {
          count: length,
          canonical_id: .[0].id,
          name: .[0].name,
          username: .[0].login.username,
          duplicate_ids: (.[1:] | map(.id)),
          passkey_items: [ .[] | select(has_passkey(.)) | .id ]
        }
      )
    '
}

compute_partial_duplicates() {
    local raw_json="$1"
    echo "$raw_json" | jq "${JQ_DOMAIN_PASSKEY_HELPERS}"'
      map(
        select(.type == 1 and (.login.username // "") != "") |
        . as $it |
        (item_main_domains($it)) as $doms |
        select(($doms | length) > 0)
      ) |
      group_by({
        user: (.login.username | ascii_downcase),
        doms: item_main_domains(.),
        has_passkey: has_passkey(.)
      }) |
      map(select(length > 1)) |
      map(
        (
          [
            (if (map(.login.username) | unique | length) > 1 then "diff username case" else empty end),
            (if (map(.login.password // "") | unique | length) > 1 then "diff passwords" else empty end),
            (if ([.[] | norm_passkeys(.login.fido2Credentials)] | unique | length) > 1 then "diff passkeys" else empty end),
            (if ([.[] | (.login.totp // "") | select(. != "")] | unique | length) > 1 then "diff TOTP" else empty end)
          ] | if length > 0 then "AUDIT ONLY: " + join(", ") else "MERGE CANDIDATE" end
        ) as $merge_note |
        {
          domain: (item_main_domains(.[0]) | join(", ")),
          username: .[0].login.username,
          item_count: length,
          merge_note: $merge_note,
          items: map({
            id: .id,
            name: .name,
            has_pw: (.login.password != null and .login.password != ""),
            has_totp: ((.login.totp // "") != ""),
            has_passkey: has_passkey(.),
            field_count: (.fields // [] | length),
            has_notes: (.notes != null and .notes != "")
          })
        }
      )
    '
}

compute_merge_plan() {
    local raw_json="$1"
    echo "$raw_json" | jq "${JQ_DOMAIN_PASSKEY_HELPERS}"'
      map(
        select(.type == 1 and (.login.username // "") != "") |
        . as $it |
        (item_main_domains($it)) as $doms |
        select(($doms | length) > 0)
      ) |
      group_by({
        u: .login.username,
        p: (.login.password // ""),
        doms: item_main_domains(.),
        has_pk: has_passkey(.)
      }) |
      map(select(length > 1)) as $clusters |

      [ $clusters[] |
        sort_by((if has_passkey(.) then 0 else 1 end), (if (.login.totp // "") != "" then 0 else 1 end)) as $sorted |
        $sorted[0] as $canonical |
        $sorted[1:] as $redundants |

        (if has_passkey($canonical) then
           ($redundants | map(select(norm_passkeys(.login.fido2Credentials) != norm_passkeys($canonical.login.fido2Credentials))) | length)
         else
           0
         end) as $unsafe_passkeys |
        ([ $sorted[] | (.login.totp // "") | select(. != "") ] | unique) as $distinct_totps |
        
        if $unsafe_passkeys > 0 then
          {
            status: "CONFLICT_MULTIPLE_PASSKEYS",
            canonical_id: $canonical.id,
            name: $canonical.name,
            username: $canonical.login.username,
            skip_deletion: true,
            conflict_items: $sorted,
            redundant_ids_to_delete: [],
            reason: "Multiple items hold independent FIDO2 Passkeys"
          }
        elif ($distinct_totps | length) > 1 then
          {
            status: "CONFLICT_MULTIPLE_TOTP",
            canonical_id: $canonical.id,
            name: $canonical.name,
            username: $canonical.login.username,
            skip_deletion: true,
            conflict_items: $sorted,
            redundant_ids_to_delete: [],
            reason: "Multiple items hold different 2FA TOTP secrets"
          }
        else
          (if ($distinct_totps | length) == 1 and (($canonical.login.totp // "") == "") then $distinct_totps[0] else "" end) as $added_totp |
          ($redundants | map(.notes // "") | map(select(. != "" and . != ($canonical.notes // ""))) | unique | join("\n---\n")) as $extra_notes |
          ([ $redundants[].fields[]? | select(.name as $n | (($canonical.fields // []) | map(.name) | index($n)) == null) ] | unique_by(.name)) as $new_fields |
          ([ $redundants[].login.uris[]? | select(.uri as $u | (($canonical.login.uris // []) | map(.uri) | index($u)) == null) ] | unique_by(.uri)) as $new_uris |

          ($canonical |
            if $added_totp != "" then
              .login.totp = $added_totp
            else . end |
            if $extra_notes != "" then
              .notes = (if (.notes // "") == "" then $extra_notes else (.notes + "\n---\n" + $extra_notes) end)
            else . end |
            if ($new_fields | length) > 0 then
              .fields = ((.fields // []) + $new_fields)
            else . end |
            if ($new_uris | length) > 0 then
              .login.uris = ((.login.uris // []) + $new_uris)
            else . end
          ) as $merged_item |

          {
            status: "MERGED",
            canonical_id: $canonical.id,
            name: $canonical.name,
            username: $canonical.login.username,
            canonical_changed: ($merged_item != $canonical),
            original_canonical: $canonical,
            added_totp: ($added_totp != ""),
            added_notes: $extra_notes,
            added_fields: $new_fields,
            added_uris: ($new_uris | map(.uri)),
            redundant_items: $redundants,
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

    log_info "Partial audit clusters: ${BOLD}$group_count${RESET} (audit view; merges strictly require identical user, pw, passkey & TOTP)"
    if [[ "$group_count" -gt 0 ]]; then
        printf "\n${BOLD}%-22s │ %-20s │ %s${RESET}\n" "DOMAIN" "USERNAME" "AUDIT COMPARISON & MERGE ELIGIBILITY"
        printf "%s\n" "───────────────────────┼──────────────────────┼────────────────────────────────────────────────────────"
        echo "$partial_groups" | jq -r '.[] | "\(.domain[0:22])|\(.username[0:20])|\(.items | map("[\(.id[0:8])... pw:\(.has_pw) totp:\(.has_totp) passkey:\(.has_passkey) fields:\(.field_count)]") | join(" vs ")) (\(.merge_note))"' |
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

print_merge_plan_verbose_cards() {
    local merge_result="$1"
    local total_all curr=0 entry_json
    total_all=$(echo "$merge_result" | jq 'length')
    local all_entries
    all_entries=$(echo "$merge_result" | jq -c '.[]')
    while IFS= read -r -u 3 entry_json; do
        [[ -z "$entry_json" ]] && continue
        curr=$((curr + 1))
        print_verbose_merge_cluster_card "$curr" "$total_all" "$entry_json"
    done 3<<< "$all_entries"
}

# Single-cluster merge & deletion executor (used identically for 1 cluster or all clusters)
execute_single_merge_cluster() {
    local entry_json="$1"
    local canonical_changed canonical_id cname can_ok=true
    canonical_changed=$(printf '%s\n' "$entry_json" | jq -r '.canonical_changed')
    canonical_id=$(printf '%s\n' "$entry_json" | jq -r '.canonical_id')
    cname=$(printf '%s\n' "$entry_json" | jq -r '.name // .canonical_id')

    CLUSTER_DEL_OK=0
    CLUSTER_DEL_FAIL=0

    if [[ "$canonical_changed" == "true" ]]; then
        local merged_item_json
        merged_item_json=$(printf '%s\n' "$entry_json" | jq -c '.merged_item')
        if ! bw_update_item "$merged_item_json"; then
            can_ok=false
            log_warn "Skipping deletion of duplicates for '$cname' because canonical update failed."
        fi
    elif [[ "$VERBOSE" == true ]]; then
        log_info "[VERBOSE] Canonical item $canonical_id ('$cname') already holds all attributes — no edit required."
    fi

    if [[ "$can_ok" == true ]]; then
        local del_id
        while IFS= read -r del_id; do
            [[ -z "$del_id" ]] && continue
            if bw_delete_single_item "$del_id" "$cname"; then
                CLUSTER_DEL_OK=$((CLUSTER_DEL_OK + 1))
            else
                CLUSTER_DEL_FAIL=$((CLUSTER_DEL_FAIL + 1))
            fi
        done < <(printf '%s\n' "$entry_json" | jq -r '.redundant_ids_to_delete[]?')
    else
        CLUSTER_DEL_FAIL=$(printf '%s\n' "$entry_json" | jq '.redundant_ids_to_delete | length')
    fi

    [[ $CLUSTER_DEL_FAIL -eq 0 ]]
}

# --- OPERATION: Execute Merge Plan ---
# Changing one cluster vs changing all runs the exact same per-cluster execution loop.
execute_merge_plan() {
    local raw_json="$1"
    local merge_result="$2"
    local total_deletions="$3"

    print_merge_plan_table "$merge_result"
    printf "\n${YELLOW}Planned cleanup scope:${RESET} %d redundant item(s) to be removed (Passkeys & 2FA TOTP secrets strictly protected).\n" "$total_deletions"

    if [[ "$VERBOSE" == true ]]; then
        local conflict_entries conflict_total c_idx=0 c_json
        conflict_entries=$(echo "$merge_result" | jq -c '.[] | select(.skip_deletion == true)')
        conflict_total=$(echo "$merge_result" | jq '[.[] | select(.skip_deletion == true)] | length')
        if [[ "$conflict_total" -gt 0 ]]; then
            while IFS= read -r -u 3 c_json; do
                [[ -z "$c_json" ]] && continue
                c_idx=$((c_idx + 1))
                print_verbose_merge_cluster_card "$c_idx" "$conflict_total" "$c_json"
            done 3<<< "$conflict_entries"
        fi
    fi

    if [[ "$total_deletions" -eq 0 ]]; then
        log_success "No redundant items eligible for deletion."
        return 0
    fi

    local preview_only=false
    local ask_each=false
    local prev_verbose="$VERBOSE"
    if [[ "$INTERACTIVE" == true ]]; then
        if [[ "$VERBOSE" == true ]]; then
            ask_each=true
        else
            if ! prompt_confirmation "Deletion of $total_deletions redundant duplicate(s)"; then
                return 0
            fi
            if [[ "$CONFIRM_ACTION" == "verify" ]]; then
                ask_each=true
            fi
        fi
    elif [[ "$MODE" == "preview" ]]; then
        preview_only=true
    fi

    if [[ "$preview_only" != true && "$EXEC_TARGET" == "file" && -z "$OUTPUT_FILE" ]]; then
        log_error "Input '--file' mode is read-only. Re-run with '--output <file>' to save cleaned data."
        return 1
    fi

    if [[ "$ask_each" == true && "$VERBOSE" != true ]]; then
        VERBOSE=true
        log_info "Switched to one-by-one verify mode for this operation."
        local conflict_entries conflict_total c_idx=0 c_json
        conflict_entries=$(echo "$merge_result" | jq -c '.[] | select(.skip_deletion == true)')
        conflict_total=$(echo "$merge_result" | jq '[.[] | select(.skip_deletion == true)] | length')
        if [[ "$conflict_total" -gt 0 ]]; then
            while IFS= read -r -u 3 c_json; do
                [[ -z "$c_json" ]] && continue
                c_idx=$((c_idx + 1))
                print_verbose_merge_cluster_card "$c_idx" "$conflict_total" "$c_json"
            done 3<<< "$conflict_entries"
        fi
    fi

    if [[ "$preview_only" == true && "$VERBOSE" != true ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No items deleted. Run with -i or --apply to execute."
        return 0
    fi

    WORKING_VAULT_JSON="$raw_json"
    local merge_entries total_clusters curr_cluster=0 entry_json
    local deleted_ok=0 deleted_fail=0 skipped_clusters=0 applied_clusters=0
    local CLUSTER_DEL_OK=0 CLUSTER_DEL_FAIL=0
    merge_entries=$(echo "$merge_result" | jq -c '.[] | select(.status == "MERGED")')
    total_clusters=$(echo "$merge_result" | jq '[.[] | select(.status == "MERGED")] | length')

    while IFS= read -r -u 3 entry_json; do
        [[ -z "$entry_json" ]] && continue
        curr_cluster=$((curr_cluster + 1))

        if [[ "$VERBOSE" == true ]]; then
            print_verbose_merge_cluster_card "$curr_cluster" "$total_clusters" "$entry_json"
        else
            render_progress "$curr_cluster" "$total_clusters" "Merging clusters"
        fi

        [[ "$preview_only" == true ]] && continue

        local cluster_del_count
        cluster_del_count=$(printf '%s\n' "$entry_json" | jq '.redundant_ids_to_delete | length')

        if [[ "$ask_each" == true ]]; then
            prompt_verbose_item_decision "Execute cluster [$curr_cluster/$total_clusters] (delete $cluster_del_count duplicate(s))?"
            case "$VERBOSE_DECISION" in
                no)
                    skipped_clusters=$((skipped_clusters + 1))
                    log_info "Skipped cluster [$curr_cluster/$total_clusters]."
                    continue
                    ;;
                quit)
                    local rem=$((total_clusters - curr_cluster + 1))
                    log_warn "Cancelled remaining $rem cluster(s)."
                    break
                    ;;
                all)
                    ask_each=false
                    local rem_clusters=$((total_clusters - curr_cluster + 1))
                    log_info "Applying this and remaining cluster(s) ($rem_clusters cluster(s)) without further prompts..."
                    ;;
            esac
        fi

        execute_single_merge_cluster "$entry_json" || true
        applied_clusters=$((applied_clusters + 1))
        deleted_ok=$((deleted_ok + CLUSTER_DEL_OK))
        deleted_fail=$((deleted_fail + CLUSTER_DEL_FAIL))
    done 3<<< "$merge_entries"

    if [[ "$preview_only" == true ]]; then
        printf "\n" >&2
        log_warn "[DRY-RUN] No items deleted. Run with -i or --apply to execute."
        return 0
    fi

    VERBOSE="$prev_verbose"

    local skip_note=""
    [[ $skipped_clusters -gt 0 ]] && skip_note=" ($skipped_clusters cluster(s) skipped)"

    if [[ -n "$OUTPUT_FILE" && $applied_clusters -gt 0 ]]; then
        log_success "Cleaned vault data saved to: $OUTPUT_FILE"
    fi

    if [[ $deleted_ok -eq 0 && $deleted_fail -eq 0 ]]; then
        log_warn "No duplicate clusters were applied${skip_note}."
    elif [[ $deleted_fail -eq 0 ]]; then
        log_success "Cleanup completed: $deleted_ok duplicate(s) deleted${skip_note}."
    else
        log_warn "Cleanup completed with errors: $deleted_ok duplicate(s) deleted, $deleted_fail skipped/failed${skip_note}."
        return 1
    fi
    return 0
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

    local exact_clusters content_clusters partial_clusters merge_clusters total_deletions passkey_conflicts totp_conflicts
    exact_clusters=$(echo "$exact_dups" | jq 'length')
    content_clusters=$(echo "$content_dups" | jq 'length')
    partial_clusters=$(echo "$partial_groups" | jq 'length')
    merge_clusters=$(echo "$merge_result" | jq '[.[] | select(.status == "MERGED")] | length')
    total_deletions=$(echo "$merge_result" | jq '[.[].redundant_ids_to_delete[]?] | length')
    passkey_conflicts=$(echo "$merge_result" | jq '[.[] | select(.status == "CONFLICT_MULTIPLE_PASSKEYS")] | length')
    totp_conflicts=$(echo "$merge_result" | jq '[.[] | select(.status == "CONFLICT_MULTIPLE_TOTP")] | length')

    printf "\n" >&2
    printf "${BOLD}${CYAN}╭────────────────────────────────────────────────────────────────────────────╮${RESET}\n" >&2
    printf "${BOLD}${CYAN}│ %-74s │${RESET}\n" "  DUPLICATE AUDIT REPORT" >&2
    printf "${BOLD}${CYAN}╰────────────────────────────────────────────────────────────────────────────╯${RESET}\n" >&2
    printf "  • Total items scanned:              ${BOLD}%d${RESET}\n" "$total_items" >&2
    printf "  • Passkeys protected (Safety Armor): ${BOLD}%d 🔒${RESET}\n" "$passkey_count" >&2
    printf "  • Tier 1 Exact duplicate clusters:  ${BOLD}%d${RESET} (Identical data & timestamps)\n" "$exact_clusters" >&2
    printf "  • Tier 2 Content duplicate clusters:${BOLD}%d${RESET} (Identical data, timestamps ignored)\n" "$content_clusters" >&2
    printf "  • Tier 3 Partial audit clusters:    ${BOLD}%d${RESET} (Same main domain & username; audit view)\n" "$partial_clusters" >&2
    printf "  • Eligible merge clusters:          ${BOLD}%d${RESET}\n" "$merge_clusters" >&2
    if [[ "$passkey_conflicts" -gt 0 ]]; then
        printf "  • Passkey conflicts detected:       ${BOLD}${YELLOW}%d ⚠️${RESET} (Protected from merge)\n" "$passkey_conflicts" >&2
    fi
    if [[ "$totp_conflicts" -gt 0 ]]; then
        printf "  • 2FA/TOTP conflicts detected:      ${BOLD}${YELLOW}%d ⚠️${RESET} (Protected from merge)\n" "$totp_conflicts" >&2
    fi
    printf "  • Redundant items safe to delete:   ${BOLD}%d${RESET}\n\n" "$total_deletions" >&2

    if [[ "$exact_clusters" -eq 0 && "$content_clusters" -eq 0 && "$partial_clusters" -eq 0 && "$total_deletions" -eq 0 ]]; then
        log_success "No duplicate items found in any tier. Your vault is clean."
        return 0
    fi

    # Interactive action prompt based on analysis findings
    while true; do
        local v_label="${DIM}OFF${RESET}"
        [[ "$VERBOSE" == true ]] && v_label="${GREEN}ON${RESET}"

        flush_tty_input
        printf "${BOLD}Duplicate Resolution Menu:${RESET}\n" >&2
        printf "  [1] Safe Merge & Cleanup (%d redundant item(s) to delete)\n" "$total_deletions" >&2
        printf "  [2] View Tier 1 details (Exact duplicates: %d cluster(s))\n" "$exact_clusters" >&2
        printf "  [3] View Tier 2 details (Content-identical: %d cluster(s))\n" "$content_clusters" >&2
        printf "  [4] View Tier 3 details (Partial matches: %d cluster(s))\n" "$partial_clusters" >&2
        printf "  [5] Preview complete merge & deletion plan\n" >&2
        printf "  [v] Toggle verbose mode (currently: %s)\n" "$v_label" >&2
        printf "  [b] Back to main menu\n\n" >&2
        printf "Selection [1-5, v, b]: " >&2

        local subchoice=""
        read_tty_line subchoice
        subchoice="$(trim_whitespace "$subchoice")"
        subchoice="${subchoice:-b}"

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
                if [[ "$VERBOSE" == true ]]; then
                    print_merge_plan_verbose_cards "$merge_result"
                fi
                ;;
            v|V)
                if [[ "$VERBOSE" == true ]]; then
                    VERBOSE=false
                    log_info "Verbose mode disabled."
                else
                    VERBOSE=true
                    log_success "Verbose mode enabled (per-item diffs & step-by-step confirmation)."
                fi
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
    local raw_json=""
    local needs_refresh=true

    while true; do
        if [[ "$needs_refresh" == true ]]; then
            if ! raw_json="$(fetch_vault_json)"; then
                exit 1
            fi
            needs_refresh=false
        fi

        local v_label="${DIM}OFF${RESET}"
        [[ "$VERBOSE" == true ]] && v_label="${GREEN}ON${RESET}"

        flush_tty_input
        printf "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}\n"
        printf "${BOLD}${CYAN}║     VAULTWARDEN-CLEANUP INTERACTIVE WIZARD                           ║${RESET}\n"
        printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}\n"
        if [[ -n "$CONNECTED_ACCOUNT" ]]; then
            printf " ${DIM}Connected: %s (%s)${RESET}\n\n" "$EXEC_TARGET" "$CONNECTED_ACCOUNT"
        fi
        printf " [1] Fix KeePass URLs (migrate URLs from notes/fields for entries without a URL)\n"
        printf " [2] Fix missing names (set 'Domain (Username)' for entries without a name or '--')\n"
        printf " [3] Analyze & resolve duplicates (smart multi-tier audit & merge)\n"
        printf " [v] Toggle verbose mode (currently: %s)\n" "$v_label"
        if [[ "$EXEC_TARGET" == "local" || "$EXEC_TARGET" == "docker" ]]; then
            printf " [l] Logout Bitwarden CLI session\n"
        fi
        printf " [q] Quit\n\n"
        if [[ "$EXEC_TARGET" == "local" || "$EXEC_TARGET" == "docker" ]]; then
            printf "Selection [1-3, v, l, q]: "
        else
            printf "Selection [1-3, v, q]: "
        fi

        local menu_choice=""
        read_tty_line menu_choice
        menu_choice="$(trim_whitespace "$menu_choice")"
        menu_choice="${menu_choice:-q}"

        case "$menu_choice" in
            1)
                op_fix_uris "$raw_json" || true
                needs_refresh=true
                ;;
            2)
                op_fix_names "$raw_json" || true
                needs_refresh=true
                ;;
            3)
                op_duplicate_workflow "$raw_json" || true
                needs_refresh=true
                ;;
            v|V)
                if [[ "$VERBOSE" == true ]]; then
                    VERBOSE=false
                    log_info "Verbose mode disabled."
                else
                    VERBOSE=true
                    log_success "Verbose mode enabled (per-item diffs & step-by-step confirmation)."
                fi
                ;;
            l|L)
                if [[ "$EXEC_TARGET" == "local" || "$EXEC_TARGET" == "docker" ]]; then
                    run_bw_capture logout --nointeraction || true
                    BW_SESSION=""
                    export BW_SESSION
                    log_success "Logged out of Bitwarden CLI."
                    break
                else
                    log_error "Invalid selection: $menu_choice"
                fi
                ;;
            q|Q)
                log_info "Interactive wizard closed."
                break
                ;;
            *)
                log_error "Invalid selection: $menu_choice"
                ;;
        esac
    done
}

# --- Main Entry Point ---
normalize_cli_path() {
    local p="${1:-}"
    if [[ "$p" =~ ^[A-Za-z]:([\\/]|$) ]] || [[ "$p" == *\\* ]]; then
        if command -v wslpath >/dev/null 2>&1; then
            p="$(wslpath -u "$p" 2>/dev/null || printf '%s' "$p")"
        elif command -v cygpath >/dev/null 2>&1; then
            p="$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p")"
        fi
    fi
    printf '%s' "$p"
}

main() {
    local command=""
    local tier="exact"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --server)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a URL argument."; usage; }
                SERVER_URL="$2"
                shift 2
                ;;
            --bootstrap-bw)
                BOOTSTRAP_BW=true
                shift
                ;;
            --file)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a file path."; usage; }
                INPUT_FILE="$(normalize_cli_path "$2")"
                EXEC_TARGET="file"
                shift 2
                ;;
            --output)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a file path."; usage; }
                OUTPUT_FILE="$(normalize_cli_path "$2")"
                shift 2
                ;;
            --mock-bw)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a directory path."; usage; }
                MOCK_BW_DIR="$(normalize_cli_path "$2")"
                EXEC_TARGET="mock"
                shift 2
                ;;
            --docker)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a container name or ID."; usage; }
                DOCKER_CONTAINER="$2"
                EXEC_TARGET="docker"
                shift 2
                ;;
            --apply)
                MODE="apply"
                shift
                ;;
            --all-uris)
                INCLUDE_EXISTING_URIS=true
                shift
                ;;
            --tier)
                [[ $# -lt 2 ]] && { log_error "Option '$1' requires a tier name."; usage; }
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

    check_dependencies

    if [[ "$command" == "test-run" ]]; then
        if [[ -f "$SCRIPT_DIR/tests/run_tests.sh" ]]; then
            exec "$SCRIPT_DIR/tests/run_tests.sh"
        elif [[ -f "./tests/run_tests.sh" ]]; then
            exec "./tests/run_tests.sh"
        else
            log_error "Test runner not found at ./tests/run_tests.sh"
            exit 1
        fi
    fi

    # Normalize MOCK_BW_DIR if subfolder mock_vault exists
    if [[ "$EXEC_TARGET" == "mock" && -n "$MOCK_BW_DIR" ]]; then
        if [[ ! -f "$MOCK_BW_DIR/items.json" && -f "$MOCK_BW_DIR/mock_vault/items.json" ]]; then
            MOCK_BW_DIR="$MOCK_BW_DIR/mock_vault"
        fi
    fi

    # If no command passed and -i is requested (or invoked on an interactive terminal), enter wizard
    if [[ -z "$command" ]]; then
        if [[ "$INTERACTIVE" == true ]] || [[ -t 0 ]]; then
            INTERACTIVE=true
        else
            log_error "No command specified. Use -i for interactive mode or -h for help."
            usage
        fi
    fi

    log_info "Initializing [Target: ${BOLD}$EXEC_TARGET${RESET}, Mode: ${BOLD}$MODE${RESET}, Interactive: ${BOLD}$INTERACTIVE${RESET}, Verbose: ${BOLD}$VERBOSE${RESET}]"
    prepare_target_environment

    if [[ "$INTERACTIVE" == true && -z "$command" ]]; then
        run_interactive_wizard
        exit 0
    fi

    local vault_data
    if ! vault_data="$(fetch_vault_json)"; then
        exit 1
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
