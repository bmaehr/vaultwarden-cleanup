#!/usr/bin/env bash
set -euo pipefail
MOCK_STORE="${MOCK_VAULT_STORE:-tests/mock_vault/items.json}"
cmd="${1:-}"
subcmd="${2:-}"

case "$cmd" in
    list)
        if [[ "$subcmd" == "items" ]]; then
            cat "$MOCK_STORE"
        else
            echo "[]"
        fi
        ;;
    get)
        item_id="${3:-}"
        jq --arg id "$item_id" '.[] | select(.id == $id)' "$MOCK_STORE"
        ;;
    delete)
        item_id="${3:-}"
        printf '{"success":true,"message":"Item %s deleted from mock store"}\n' "$item_id"
        ;;
    *)
        echo "Mock BW CLI v1.0.0 (Offline Test Simulation Mode)"
        ;;
esac
