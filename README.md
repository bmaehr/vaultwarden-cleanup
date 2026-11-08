# vaultwarden-cleanup

Interactive wizard and CLI automation tool in Bash and `jq` for cleaning up KeePass imports, restoring missing entry names, and safely deduplicating Bitwarden / Vaultwarden vaults with strict passkey protection.

## Requirements

- `bash` (>= 4.0)
- `jq`
- Optional for live vaults: Bitwarden CLI (`bw`) — if missing, `-i` / `--bootstrap-bw` automatically downloads the official standalone `bw` binary into `./.bin/bw`.

---

## Quick Start

```bash
# Live Vaultwarden / Bitwarden server (auto-downloads './.bin/bw' if needed,
# guides through server URL, login/2FA/API key, unlock, and vault sync)
./vaultwarden-cleanup.sh -i

# Live interactive wizard with step-by-step verbose diffs & [y/n/a/q] prompts
./vaultwarden-cleanup.sh -i -v

# Pre-configure server URL or reuse an existing BW_SESSION
./vaultwarden-cleanup.sh -i --server https://vault.example.com

# Operate offline on an exported Bitwarden JSON file
./vaultwarden-cleanup.sh -i --file export.json --output clean_vault.json

# Offline simulation against the built-in mock vault store
./vaultwarden-cleanup.sh -i --mock-bw tests/mock_vault

# Run against a Bitwarden CLI container (do not target the vaultwarden/server container)
./vaultwarden-cleanup.sh -i --docker bw-cli-container
```

> **Note:** `vaultwarden/server` containers only store encrypted ciphertext and do not include `bw`. Passing a `vaultwarden/server` container ID to `--docker` offers to switch to the local `./.bin/bw` binary automatically using the container's `DOMAIN` environment variable as a hint.

### Windows (`vaultwarden-cleanup.bat`)

Run [`vaultwarden-cleanup.bat`](vaultwarden-cleanup.bat) from Command Prompt, PowerShell, or Explorer. It automatically detects **WSL** (recommended, full `jq` and standalone `./.bin/bw` support) and falls back to **Git Bash** (`bash.exe`) if available:

```bat
vaultwarden-cleanup.bat -i
vaultwarden-cleanup.bat --file C:\path\to\export.json fix-uris --apply --output C:\path\to\clean_vault.json
```

Optional overrides: `set VWC_RUNNER=wsl` or `bash`, `set VWC_WSL_DISTRO=<distro>`, `set VWC_BASH_EXE=C:\path\to\bash.exe`.

---

## Features & Cleanup Operations

1. **Fix KeePass URLs (`fix-uris`)**
   - Extracts `http://` / `https://` URLs from free-text `notes` and non-hidden custom `fields` into `login.uris`.
   - **Default scope:** only updates entries that do **not** have any URL yet (preserves extraction order). Pass `--all-uris` (or pick `[2]` when prompted interactively) to also append links found on entries that already have URIs.
2. **Fix Missing Names (`fix-names`)**
   - Generates `Domain (Username)` names for login items whose `name` is `null`, empty/whitespace, or `--`.
3. **Smart Duplicate Analysis & Safe Merge (`duplicates`, `find-duplicates`, `merge-duplicates`)**
   - **Tier 1 (`exact`):** Identical attributes and server timestamps (ignores `id`).
   - **Tier 2 (`content`):** Identical login, password, URIs, notes, and custom fields (ignores timestamps and `id`).
   - **Tier 3 (`partial`):** Groups items sharing the same domain and username for attribute consolidation.
   - **Passkey & Data-Loss Armor:** Items holding `fido2Credentials` are always kept as canonical records and never deleted. Clusters with multiple distinct passkeys are flagged as `CONFLICT_MULTIPLE_PASSKEYS` and skipped. Redundant duplicates are only deleted after the canonical item update succeeds.

---

## Confirmation & Verify Mode

Every write operation shows a summary table first. Changes and deletions run through the same single-item/single-cluster executor and require confirmation (unless `--apply` is passed):

- **Standard Confirmation (`-i`):**
  - `[y]` Yes (apply all)
  - `[v]` Verify one-by-one (switches to diff cards + per-item prompts for that operation)
  - `[N]` No, Cancel (Default)
- **Verbose / Verify Mode (`-v` / `--verbose`, `[v]` menu toggle, or `v` at confirmation):**
  - Prints a full before/after diff card for every item or duplicate cluster with sensitive values (`password`, `totp`, hidden custom fields `type == 1`) masked as `********`, followed by:
    - `[y]` Apply this item/cluster
    - `[n]` Skip this item/cluster (Default)
    - `[a]` Apply this and all remaining items/clusters without further prompts
    - `[q]` Cancel remaining items/clusters

---

## CLI Reference

### Commands

| Command | Description |
| :--- | :--- |
| `fix-uris` | Migrate URLs from notes/fields into `login.uris` (default: entries without a URL) |
| `fix-names` | Set `Domain (Username)` names for entries without a name or named `--` |
| `find-duplicates` | List duplicate clusters (`--tier exact \| content \| partial`) |
| `merge-duplicates` | Preview or execute safe attribute merge & duplicate cleanup |
| `duplicates` | Full duplicate audit report + interactive resolution menu |
| `test-run` | Run the offline simulation test suite |

### Common Options

| Option | Description |
| :--- | :--- |
| `-i`, `--interactive` | Launch interactive wizard / confirmation flow |
| `-v`, `--verbose` | Enable per-item/cluster diff cards (secrets masked) & `[y/n/a/q]` prompts |
| `--apply` | Apply changes without interactive prompts (default is dry-run preview) |
| `--all-uris` | With `fix-uris`, also append extracted URLs to items with existing URIs |
| `--server <url>` | Configure Vaultwarden / Bitwarden server URL |
| `--bootstrap-bw` | Auto-download standalone `bw` into `./.bin/bw` if missing |
| `--file <path>` | Operate on a local JSON export instead of live `bw` |
| `--output <path>` | Write updated JSON to `<path>` when using `--file` |
| `--mock-bw <dir>` | Simulate live CLI state against a mock store directory |
| `--docker <container>` | Run `bw` inside a Bitwarden CLI container |
| `--tier <name>` | Duplicate strictness tier: `exact` (default), `content`, `partial` |
| `-h`, `--help` | Show CLI help |

### CLI Examples

```bash
# Dry-run verbose preview on a JSON export (no changes written)
./vaultwarden-cleanup.sh -v --file export.json merge-duplicates

# Apply KeePass URL migration only for entries without a URL
./vaultwarden-cleanup.sh --file export.json fix-uris --apply --output clean_vault.json

# Include entries that already have URIs when migrating KeePass links
./vaultwarden-cleanup.sh --file export.json fix-uris --all-uris --apply --output clean_vault.json

# Inspect content-identical duplicates
./vaultwarden-cleanup.sh --file export.json find-duplicates --tier content
```

---

## Running Tests

```bash
./vaultwarden-cleanup.sh test-run
# or directly:
./tests/run_tests.sh
```
