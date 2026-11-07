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

out1=$("$BIN" --file "$SCRIPT_DIR/fixture_keepass_uris.json" fix-uris 2>&1)
assert_contains "$out1" "https://internal.company.net/login" "1.1: Extracts URL from free-text notes"
assert_contains "$out1" "https://auth.company.net/sso" "1.2: Extracts URL from custom field LegacySSO"

out2=$("$BIN" --file "$SCRIPT_DIR/fixture_generic_names.json" fix-names 2>&1)
assert_contains "$out2" "login.microsoftonline.com (b.maehr@mvb-online.de)" "2.1: Replaces raw URL with 'Domain (user)'"
assert_contains "$out2" "pve-cluster.lan (admin)" "2.2: Generates title from empty name using host & user"

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

out6=$("$BIN" --file "$SCRIPT_DIR/fixture_duplicates.json" merge-duplicates 2>&1)
assert_contains "$out6" "cccc3333-0000-0000-0000-000000000001" "6.1: Proposes password-only redundant item for deletion"
assert_not_contains "$out6" "cccc3333-0000-0000-0000-000000000002" "6.2: STRICT ARMOR: Protects passkey ID from deletion"

cp "$SCRIPT_DIR/fixture_duplicates.json" "$SCRIPT_DIR/mock_vault/items.json"
out7=$("$BIN" --mock-bw "$SCRIPT_DIR/mock_vault" find-duplicates --tier exact 2>&1)
assert_contains "$out7" "Target: mock" "7.1: Runs through simulated Mock BW CLI environment"

printf "\n${BOLD}${CYAN}====================================================================${NC}\n"
printf "Summary: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass_count" "$fail_count"
printf "${BOLD}${CYAN}====================================================================${NC}\n\n"

if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
