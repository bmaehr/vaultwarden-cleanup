#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$PARENT_DIR/vault_manager.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass_count=0
fail_count=0

assert_contains() {
    local text="$1"
    local substring="$2"
    local test_name="$3"
    if echo "$text" | grep -q -- "$substring"; then
        printf "${GREEN}[PASS]${NC} %s\n" "$test_name"
        pass_count=$((pass_count + 1))
    else
        printf "${RED}[FAIL]${NC} %s (Expected: '%s')\n" "$test_name" "$substring"
        fail_count=$((fail_count + 1))
    fi
}

assert_not_contains() {
    local text="$1"
    local substring="$2"
    local test_name="$3"
    if ! echo "$text" | grep -q -- "$substring"; then
        printf "${GREEN}[PASS]${NC} %s\n" "$test_name"
        pass_count=$((pass_count + 1))
    else
        printf "${RED}[FAIL]${NC} %s (Should NOT contain: '%s')\n" "$test_name" "$substring"
        fail_count=$((fail_count + 1))
    fi
}

printf "\n${BOLD}${CYAN}====================================================================${NC}\n"
printf "${BOLD}${CYAN}   OFFLINE SIMULATION SUITE: VAULTWARDEN & BITWARDEN TOOLKIT       ${NC}\n"
printf "${BOLD}${CYAN}====================================================================${NC}\n\n"

if ! command -v jq >/dev/null 2>&1; then
    printf "${RED}[ERROR]${NC} 'jq' is required.\n"
    exit 1
fi

# --- 1. KeePass URI Tests ---
out1=$("$BIN" --file "$SCRIPT_DIR/fixture_keepass_uris.json" fix-uris 2>&1)
assert_contains "$out1" "https://internal.company.net/login" "1.1: Extracts URL from free-text notes"
assert_contains "$out1" "https://auth.company.net/sso" "1.2: Extracts URL from custom field LegacySSO"

cp "$SCRIPT_DIR/fixture_keepass_uris.json" "$SCRIPT_DIR/mock_vault/items.json"
out1_apply=$("$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" --apply fix-uris 2>&1)
assert_contains "$out1_apply" "1 item(s) updated" "1.3: Applies URI extraction directly to mock store"
saved_uri=$(jq -r '.[] | select(.id == "11111111-1111-1111-1111-111111111111") | .login.uris[0].uri' "$SCRIPT_DIR/mock_vault/items.json")
if [[ "$saved_uri" == "https://internal.company.net/login" ]]; then
    printf "${GREEN}[PASS]${NC} 1.4: Verified migrated URI persisted in items.json\n"
    pass_count=$((pass_count + 1))
else
    printf "${RED}[FAIL]${NC} 1.4: Persisted URI mismatch: %s\n" "$saved_uri"
    fail_count=$((fail_count + 1))
fi

# --- 2. Descriptive Names Tests ---
out2=$("$BIN" --file "$SCRIPT_DIR/fixture_generic_names.json" fix-names 2>&1)
assert_contains "$out2" "login.microsoftonline.com (b.maehr@mvb-online.de)" "2.1: Replaces raw URL with 'Domain (user)'"
assert_contains "$out2" "pve-cluster.lan (admin)" "2.2: Generates title from empty name using host & user"

cp "$SCRIPT_DIR/fixture_generic_names.json" "$SCRIPT_DIR/mock_vault/items.json"
out2_apply=$("$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" --apply fix-names 2>&1)
assert_contains "$out2_apply" "2 name(s) updated" "2.3: Applies descriptive names directly to mock store"
saved_name=$(jq -r '.[] | select(.id == "44444444-4444-4444-4444-444444444444") | .name' "$SCRIPT_DIR/mock_vault/items.json")
if [[ "$saved_name" == "pve-cluster.lan (admin)" ]]; then
    printf "${GREEN}[PASS]${NC} 2.4: Verified generated name persisted in items.json\n"
    pass_count=$((pass_count + 1))
else
    printf "${RED}[FAIL]${NC} 2.4: Persisted name mismatch: %s\n" "$saved_name"
    fail_count=$((fail_count + 1))
fi

# --- 3. Duplicate Detection Tiers ---
out3=$("$BIN" --file "$SCRIPT_DIR/fixture_duplicates.json" find-duplicates --tier exact 2>&1)
assert_contains "$out3" "Exact duplicate clusters: 1" "3.1: Identifies exact duplicates with matching timestamps"
assert_contains "$out3" "app.teamgantt.com" "3.2: Contains teamgantt pair"
assert_not_contains "$out3" "lucid.app" "3.3: Differentiates items with differing creation/revision dates"

out4=$("$BIN" --file "$SCRIPT_DIR/fixture_duplicates.json" find-duplicates --tier content 2>&1)
assert_contains "$out4" "Content-identical duplicate clusters: 3" "4.1: Groups items by payload, ignoring timestamps"
assert_contains "$out4" "lucid.app" "4.2: Successfully identifies lucid.app despite differing dates"
assert_contains "$out4" "LOCKED 🔒" "4.3: Flags passkey-bearing item as LOCKED"

out5=$("$BIN" --file "$SCRIPT_DIR/fixture_duplicates.json" find-duplicates --tier partial 2>&1)
assert_contains "$out5" "email.android.com" "5.1: Finds accounts with same domain & user but differing fields"

# --- 4. Merge Duplicates & Passkey Armor ---
out6=$("$BIN" --file "$SCRIPT_DIR/fixture_duplicates.json" merge-duplicates 2>&1)
assert_contains "$out6" "cccc3333-0000-0000-0000-000000000001" "6.1: Proposes password-only redundant item for deletion"
assert_not_contains "$out6" "cccc3333-0000-0000-0000-000000000002" "6.2: STRICT ARMOR: Protects passkey ID from deletion"

# --- 5. Mock BW Environment & Directory Fallback ---
cp "$SCRIPT_DIR/fixture_all.json" "$SCRIPT_DIR/mock_vault/items.json"
out7=$("$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" find-duplicates --tier exact 2>&1)
assert_contains "$out7" "Target: mock" "7.1: Runs through simulated Mock BW CLI environment"

out7_fallback=$("$BIN" --mock-bw "$SCRIPT_DIR" find-duplicates --tier exact 2>&1)
assert_contains "$out7_fallback" "Exact duplicate clusters: 1" "7.2: Automatically resolves parent directory to mock_vault"

out8=$(echo "b" | "$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" duplicates 2>&1)
assert_contains "$out8" "DUPLICATE AUDIT REPORT" "8.1: Combined duplicate audit report generates correctly"
assert_contains "$out8" "Redundant items safe to delete:" "8.2: Evaluates eligible deletions and passkeys"

# --- 6. End-to-End Apply on Full Mock Store ---
out9=$("$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" --apply merge-duplicates 2>&1)
assert_contains "$out9" "Cleanup completed:" "9.1: Successfully executes merge and deletions in mock store"
rem_items=$(jq 'length' "$SCRIPT_DIR/mock_vault/items.json")
if [[ "$rem_items" -eq 9 ]]; then
    printf "${GREEN}[PASS]${NC} 9.2: Correct count of remaining items after merge cleanup (9 items)\n"
    pass_count=$((pass_count + 1))
else
    printf "${RED}[FAIL]${NC} 9.2: Expected 9 remaining items, found %d\n" "$rem_items"
    fail_count=$((fail_count + 1))
fi

# --- 7. Live Bitwarden CLI (.bin/bw) & Docker Error Diagnostics ---
TMP_TEST_DIR="$(mktemp -d)"
MOCK_STATE_JSON="$TMP_TEST_DIR/bw_state.json"
MOCK_LIVE_ITEMS="$TMP_TEST_DIR/live_items.json"

# Install simulated bw into ./.bin/bw temporarily if no real ./.bin/bw exists
CLEANUP_LOCAL_BIN=false
if [[ ! -e "$PARENT_DIR/.bin/bw" ]]; then
    mkdir -p "$PARENT_DIR/.bin"
    cp "$SCRIPT_DIR/mock_bw.sh" "$PARENT_DIR/.bin/bw"
    chmod +x "$PARENT_DIR/.bin/bw"
    CLEANUP_LOCAL_BIN=true
fi

# 10.1: Non-silent error on missing/stopped Docker container
out_docker_err=$("$BIN" --docker nonexistent_container_xyz123 find-duplicates 2>&1 || true)
assert_contains "$out_docker_err" "nonexistent_container_xyz123" "10.1: Reports clear error when Docker container is missing/stopped"

# 10.2: Non-interactive unauthenticated check via ./.bin/bw
cp "$SCRIPT_DIR/fixture_generic_names.json" "$MOCK_LIVE_ITEMS"
out_unauth=$(PATH="/usr/bin:/bin" MOCK_VAULT_STORE="$MOCK_LIVE_ITEMS" MOCK_BW_STATE_FILE="$MOCK_STATE_JSON" "$BIN" find-duplicates 2>&1 || true)
assert_contains "$out_unauth" "status: unauthenticated" "10.2: Detects ./.bin/bw and reports unauthenticated status clearly"

# 10.3: Interactive server config + login + sync + multi-item update via ./.bin/bw
rm -f "$MOCK_STATE_JSON"
cp "$SCRIPT_DIR/fixture_generic_names.json" "$MOCK_LIVE_ITEMS"
# Inputs: server URL -> method 1 -> email -> password -> menu 2 (fix-names) -> confirm 'y' -> Enter -> menu 'q'
out_interactive_live=$(printf "vault.example.com\n1\nadmin@example.com\ncorrect-horse-battery\n2\ny\n\nq\n" | \
    PATH="/usr/bin:/bin" MOCK_VAULT_STORE="$MOCK_LIVE_ITEMS" MOCK_BW_STATE_FILE="$MOCK_STATE_JSON" "$BIN" -i 2>&1)
assert_contains "$out_interactive_live" "Configured server: https://vault.example.com" "10.3: Normalizes and configures Vaultwarden server URL"
assert_contains "$out_interactive_live" "Vault synchronized" "10.4: Authenticates, unlocks, and synchronizes vault"
assert_contains "$out_interactive_live" "2 item(s) successfully updated" "10.5: Updates all modified items via CLI loop without stdin loss"

live_renamed_count=$(jq '[.[] | select(.name == "login.microsoftonline.com (b.maehr@mvb-online.de)" or .name == "pve-cluster.lan (admin)")] | length' "$MOCK_LIVE_ITEMS")
if [[ "$live_renamed_count" -eq 2 ]]; then
    printf "${GREEN}[PASS]${NC} 10.6: Both renamed items persisted via simulated 'bw encode' + 'bw edit'\n"
    pass_count=$((pass_count + 1))
else
    printf "${RED}[FAIL]${NC} 10.6: Expected 2 renamed items in live store, found %d\n" "$live_renamed_count"
    fail_count=$((fail_count + 1))
fi

# 10.7: Canonical update failure prevents deleting redundant duplicates (Data Loss Armor)
cp "$SCRIPT_DIR/fixture_duplicates.json" "$MOCK_LIVE_ITEMS"
orig_dup_len=$(jq 'length' "$MOCK_LIVE_ITEMS")
out_fail_edit=$(PATH="/usr/bin:/bin" BW_SESSION="mock-session-token-123" MOCK_VAULT_STORE="$MOCK_LIVE_ITEMS" MOCK_BW_STATE_FILE="$MOCK_STATE_JSON" MOCK_BW_FAIL_EDIT_ID="aaaa1111-0000-0000-0000-000000000001" "$BIN" --apply merge-duplicates 2>&1 || true)
assert_contains "$out_fail_edit" "Skipping deletion of duplicates" "10.7: Skips deleting duplicates when canonical update fails"
surviving_dup=$(jq '[.[] | select(.id == "aaaa1111-0000-0000-0000-000000000002")] | length' "$MOCK_LIVE_ITEMS")
if [[ "$surviving_dup" -eq 1 ]]; then
    printf "${GREEN}[PASS]${NC} 10.8: Redundant item preserved when canonical edit failed\n"
    pass_count=$((pass_count + 1))
else
    printf "${RED}[FAIL]${NC} 10.8: Redundant item was deleted despite canonical update failure\n"
    fail_count=$((fail_count + 1))
fi

# 10.9 & 10.10: Passing --docker <vaultwarden_server_id> detects missing 'bw', extracts DOMAIN, and switches to ./.bin/bw
cat > "$TMP_TEST_DIR/docker" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    inspect)
        fmt="${3:-}"
        if [[ "$fmt" == *"State.Running"* ]]; then
            echo "true"
        elif [[ "$fmt" == *"Config.Image"* ]]; then
            echo "vaultwarden/server:latest"
        elif [[ "$fmt" == *"Config.Env"* ]]; then
            printf "DOMAIN=https://vw.internal.lan/\nSIGNUPS_ALLOWED=false\n"
        fi
        ;;
    exec)
        # Simulate container without 'bw'
        exit 127
        ;;
    ps)
        echo "7a14e94830e4 vaultwarden/server:latest"
        ;;
esac
EOF
chmod +x "$TMP_TEST_DIR/docker"
rm -f "$MOCK_STATE_JSON"
# Inputs: '' (Yes, switch to local ./.bin/bw) -> '' (Accept detected DOMAIN https://vw.internal.lan) -> 'q' (quit auth)
out_vw_switch=$(printf "\n\nq\n" | \
    PATH="$TMP_TEST_DIR:/usr/bin:/bin" MOCK_VAULT_STORE="$MOCK_LIVE_ITEMS" MOCK_BW_STATE_FILE="$MOCK_STATE_JSON" "$BIN" --interactive --docker 7a14e94830e4 2>&1)
assert_contains "$out_vw_switch" "does not contain the Bitwarden CLI" "10.9: Detects vaultwarden/server container lacking 'bw' and offers local fallback"
assert_contains "$out_vw_switch" "Configured server: https://vw.internal.lan" "10.10: Auto-detects DOMAIN from Vaultwarden container as default server URL"

if [[ "$CLEANUP_LOCAL_BIN" == true ]]; then
    rm -rf "$PARENT_DIR/.bin"
fi
rm -rf "$TMP_TEST_DIR"

# Restore full fixture into mock store for interactive testing
cp "$SCRIPT_DIR/fixture_all.json" "$SCRIPT_DIR/mock_vault/items.json"

printf "\n${BOLD}${CYAN}====================================================================${NC}\n"
printf "Summary: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass_count" "$fail_count"
printf "${BOLD}${CYAN}====================================================================${NC}\n\n"

if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
