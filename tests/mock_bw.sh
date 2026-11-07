#!/usr/bin/env bash
set -euo pipefail

MOCK_STORE="${MOCK_VAULT_STORE:-tests/mock_vault/items.json}"
MOCK_STATE="${MOCK_BW_STATE_FILE:-}"

# Strip global flags like --nointeraction or --raw while tracking --raw
RAW_MODE=false
PASSWORD_ENV=""
APIKEY_MODE=false
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nointeraction)
            shift
            ;;
        --raw)
            RAW_MODE=true
            shift
            ;;
        --passwordenv)
            PASSWORD_ENV="${2:-}"
            shift 2
            ;;
        --apikey)
            APIKEY_MODE=true
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

cmd="${args[0]:-}"
subcmd="${args[1]:-}"

init_state_if_needed() {
    if [[ -n "$MOCK_STATE" && ! -f "$MOCK_STATE" ]]; then
        printf '{"serverUrl":"https://vault.bitwarden.com","userEmail":null,"status":"unauthenticated"}\n' > "$MOCK_STATE"
    fi
}

case "$cmd" in
    --version|-v)
        echo "2026.10.1"
        ;;
    status)
        if [[ -n "$MOCK_STATE" ]]; then
            init_state_if_needed
            st=$(jq -r '.status' "$MOCK_STATE")
            if [[ "$st" == "locked" && "${BW_SESSION:-}" == "mock-session-token-123" ]]; then
                jq '.status = "unlocked"' "$MOCK_STATE"
            else
                cat "$MOCK_STATE"
            fi
        else
            if [[ -n "${BW_SESSION:-}" ]]; then
                printf '{"serverUrl":"https://vault.example.com","userEmail":"admin@example.com","status":"unlocked"}\n'
            else
                printf '{"serverUrl":"https://vault.example.com","userEmail":"admin@example.com","status":"locked"}\n'
            fi
        fi
        ;;
    config)
        if [[ "$subcmd" == "server" ]]; then
            srv="${args[2]:-}"
            if [[ -n "$MOCK_STATE" ]]; then
                init_state_if_needed
                jq --arg s "$srv" '.serverUrl = $s' "$MOCK_STATE" > "${MOCK_STATE}.tmp"
                mv "${MOCK_STATE}.tmp" "$MOCK_STATE"
            fi
            echo "Saved setting \`config\`."
        fi
        ;;
    login)
        init_state_if_needed
        if [[ "$APIKEY_MODE" == true ]]; then
            if [[ "${BW_CLIENTID:-}" == "user.valid" && "${BW_CLIENTSECRET:-}" == "secret123" ]]; then
                if [[ -n "$MOCK_STATE" ]]; then
                    jq '.status = "locked" | .userEmail = "apikey@example.com"' "$MOCK_STATE" > "${MOCK_STATE}.tmp"
                    mv "${MOCK_STATE}.tmp" "$MOCK_STATE"
                fi
                echo "You are logged in!"
                exit 0
            else
                echo "Invalid client_id or client_secret." >&2
                exit 1
            fi
        fi
        email="${args[1]:-}"
        pw=""
        if [[ -n "$PASSWORD_ENV" ]]; then
            pw="${!PASSWORD_ENV:-}"
        fi
        if [[ "$pw" != "correct-horse-battery" ]]; then
            echo "Username or password is incorrect. Try again." >&2
            exit 1
        fi
        if [[ -n "$MOCK_STATE" ]]; then
            jq --arg e "$email" '.status = "locked" | .userEmail = $e' "$MOCK_STATE" > "${MOCK_STATE}.tmp"
            mv "${MOCK_STATE}.tmp" "$MOCK_STATE"
        fi
        if [[ "$RAW_MODE" == true ]]; then
            printf 'mock-session-token-123'
        else
            echo "You are logged in!"
        fi
        ;;
    unlock)
        pw=""
        if [[ -n "$PASSWORD_ENV" ]]; then
            pw="${!PASSWORD_ENV:-}"
        fi
        if [[ "$pw" != "correct-horse-battery" ]]; then
            echo "Invalid master password." >&2
            exit 1
        fi
        if [[ "$RAW_MODE" == true ]]; then
            printf 'mock-session-token-123'
        else
            echo "Your vault is now unlocked!"
        fi
        ;;
    logout)
        if [[ -n "$MOCK_STATE" ]]; then
            init_state_if_needed
            jq '.status = "unauthenticated" | .userEmail = null' "$MOCK_STATE" > "${MOCK_STATE}.tmp"
            mv "${MOCK_STATE}.tmp" "$MOCK_STATE"
        fi
        echo "You have logged out."
        ;;
    sync)
        echo "Syncing complete."
        ;;
    list)
        if [[ "$subcmd" == "items" ]]; then
            cat "$MOCK_STORE"
        else
            echo "[]"
        fi
        ;;
    get)
        item_id="${args[2]:-}"
        jq --arg id "$item_id" '.[] | select(.id == $id)' "$MOCK_STORE"
        ;;
    encode)
        base64 | tr -d '\r\n'
        ;;
    edit)
        if [[ "$subcmd" == "item" ]]; then
            item_id="${args[2]:-}"
            if [[ -n "${MOCK_BW_FAIL_EDIT_ID:-}" && "$item_id" == "$MOCK_BW_FAIL_EDIT_ID" ]]; then
                echo "Simulated server error editing item $item_id" >&2
                exit 1
            fi
            encoded="${args[3]:-}"
            if [[ -z "$encoded" ]]; then
                encoded="$(cat)"
            fi
            decoded="$(printf '%s' "$encoded" | base64 -d)"
            jq --arg id "$item_id" --argjson updated "$decoded" '
                map(if .id == $id then $updated else . end)
            ' "$MOCK_STORE" > "${MOCK_STORE}.tmp"
            mv "${MOCK_STORE}.tmp" "$MOCK_STORE"
            printf '%s\n' "$decoded"
        fi
        ;;
    delete)
        item_id="${args[2]:-}"
        jq --arg id "$item_id" 'map(select(.id != $id))' "$MOCK_STORE" > "${MOCK_STORE}.tmp"
        mv "${MOCK_STORE}.tmp" "$MOCK_STORE"
        printf '{"success":true,"message":"Item %s deleted from mock store"}\n' "$item_id"
        ;;
    *)
        echo "Mock BW CLI v1.0.0 (Offline Test Simulation Mode)"
        ;;
esac
