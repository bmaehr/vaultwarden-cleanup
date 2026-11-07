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

# Restore full fixture into mock store for interactive testing
cp "$SCRIPT_DIR/fixture_all.json" "$SCRIPT_DIR/mock_vault/items.json"

printf "\n${BOLD}${CYAN}====================================================================${NC}\n"
printf "Summary: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass_count" "$fail_count"
printf "${BOLD}${CYAN}====================================================================${NC}\n\n"

if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
