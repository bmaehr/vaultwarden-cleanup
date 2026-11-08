# Vaultwarden & Bitwarden Maintenance Toolkit

A robust Bash and `jq` toolkit with two operational modes:
1. **Interactive Wizard (`-i` / `--interactive`):** Menu-guided workflow with pre-execution planning, detailed analysis, and explicit confirmation prompts before any write or delete actions.
2. **Direct CLI Automation:** For headless operation, CI/CD pipelines, or quick queries.

---

## 1. Interactive Mode (Wizard & Step-by-Step Resolution)

Launch the interactive wizard against an exported JSON file or directly with your Vaultwarden setup:

```bash
# Live against your Vaultwarden server (auto-downloads standalone './.bin/bw' if missing,
# guides through server URL, login/2FA/API key, unlock, and vault sync)
./vault_manager.sh -i
# or with Verbose Mode enabled for per-item before/after diffs and [y/n/a/q] step-by-step confirmation:
./vault_manager.sh -i -v
# or specify the server URL up front:
./vault_manager.sh -i --server https://vault.example.com

# Offline simulation against mock Bitwarden environment
./vault_manager.sh -i --mock-bw tests/mock_vault
# (or simply: ./vault_manager.sh -i --mock-bw tests)

# Against an exported JSON file
./vault_manager.sh -i --file tests/fixture_all.json

# Against an existing unlocked local Bitwarden CLI session
export BW_SESSION="your_session_key"
./vault_manager.sh -i

# Against a dedicated Bitwarden CLI Docker container (note: NOT the vaultwarden/server container)
./vault_manager.sh -i --docker bw-cli-container
```

### Interactive Workflow:
1. **Main Menu:**
   - `[1]` Fix KeePass URLs (migrate URLs from notes/fields into URI matches)
   - `[2]` Fix missing names (set 'Domain (Username)' for unnamed entries)
   - `[3]` Analyze & resolve duplicates (smart multi-tier audit & passkey-protected merge)
   - `[v]` Toggle verbose mode (per-item before/after diff cards + `[y/n/a/q]` confirmation)
   - `[l]` Logout Bitwarden CLI session (when connected to a live CLI target)
   - `[q]` Quit
2. **Smart Duplicate Analysis & Resolution (Option 3):**
   - Automatically executes a multi-tier scan across:
     - **Tier 1 (Exact):** Identical payload and timestamps.
     - **Tier 2 (Content):** Identical payload, timestamps ignored.
     - **Tier 3 (Partial):** Merge candidates with same domain and username.
     - **Passkey Armor:** Audits and protects `fido2Credentials`.
   - Displays a comprehensive audit report.
   - Prompts for targeted actions based on findings:
     - `[1]` Safe Merge & Cleanup (consolidate fields, delete redundant items)
     - `[2]` View Tier 1 details
     - `[3]` View Tier 2 details
     - `[4]` View Tier 3 details
     - `[5]` Preview complete merge & deletion plan (includes full cluster diff cards when verbose is `ON`)
     - `[v]` Toggle verbose mode
     - `[b]` Back to main menu
3. **Explicit Confirmation Prompts:**
   - **Standard Mode:** Prompts once before applying the batch (`[y/N]`).
   - **Verbose Mode (`-v` / `--verbose` or `[v]` in menus):** Displays an individual before/after diff card for every modified item or duplicate cluster (with passwords, TOTP secrets, and hidden custom fields masked as `********`), followed by a per-item decision prompt:
     - `[y]` Apply this item/cluster
     - `[n]` Skip this item/cluster (Default)
     - `[a]` Apply this and all remaining items/clusters without further prompts
     - `[q]` Cancel remaining items/clusters

---

## 2. Direct CLI Commands (Automation Mode)

```bash
# 1. Full duplicate audit and interactive resolution
./vault_manager.sh --file export.json duplicates

# 2. Inspect duplicates by strictness tier
./vault_manager.sh --file export.json find-duplicates --tier content

# 3. Dry-run preview of merge plan (add -v for full per-cluster before/after diff cards)
./vault_manager.sh -v --file export.json merge-duplicates

# 4. Migrate KeePass URIs and write to clean file
./vault_manager.sh --file export.json fix-uris --output clean_vault.json
```

---

## 3. Duplicate Tiers & Passkey Safety Armor

* **Tier 1 (`exact`):** Strict comparison of all attributes via `jq`. Only `id` is ignored. Differing `creationDate` or `revisionDate` values count as distinct items.
* **Tier 2 (`content`):** Compares core payload (login, password, URIs, notes, custom fields) while ignoring server timestamps and IDs.
* **Tier 3 (`partial`):** Identifies accounts with matching domain and username that hold divergent fields (merge candidates).
* **Passkey Protection (`fido2Credentials`):**
  * Items with passkeys are **always locked as canonical records**.
  * They are **never proposed for deletion and never deleted**.
  * If multiple entries hold separate passkeys, merge deletion is aborted with `CONFLICT_MULTIPLE_PASSKEYS`.

---

## 4. Run Offline Test Suite

```bash
./vault_manager.sh test-run
# or
./tests/run_tests.sh
```
