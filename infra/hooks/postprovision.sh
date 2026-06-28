#!/bin/bash
# postprovision.sh — Updates the Easy Auth app registration redirect URI
# with the actual host FQDN (only known after Bicep provisioning).
set -euo pipefail

# ACA Sandboxes host (USE_SANDBOX=true) is a different backend with no Easy
# Auth app registration. Delegate the entire data-plane bring-up to sandbox.sh
# and skip the container-app redirect-URI fixup below.
USE_SANDBOX=$(azd env get-value USE_SANDBOX 2>/dev/null || echo "")
if [ "$(printf '%s' "$USE_SANDBOX" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    exec bash "$(dirname "$0")/sandbox.sh"
fi

# Execution layer (EXECUTION_MODE=sandbox): build the exec image + disk +
# snapshot and inject ids into the Gateway (independent of the Easy Auth fixup).
EXEC_MODE=$(azd env get-value EXECUTION_MODE 2>/dev/null || echo "")
if [ "$(printf '%s' "$EXEC_MODE" | tr '[:upper:]' '[:lower:]')" = "sandbox" ]; then
    bash "$(dirname "$0")/execution.sh" || true
fi

# Ensure az CLI is authenticated (same fix as preprovision)
if ! az account show -o none >/dev/null 2>&1; then
    if [ -n "${AZURE_CONFIG_DIR:-}" ]; then
        unset AZURE_CONFIG_DIR
    fi
    if ! az account show -o none >/dev/null 2>&1; then
        echo "[postprovision] WARNING: az not authenticated — skipping redirect URI update"
        exit 0
    fi
fi

AUTH_APP_ID=$(azd env get-value EASYAUTH_APP_ID 2>/dev/null | grep -oP '^[0-9a-f-]+$' || echo "")
if [ -z "$AUTH_APP_ID" ]; then
    echo "[postprovision] No EASYAUTH_APP_ID — skipping redirect URI update"
    exit 0
fi

FQDN=$(azd env get-value HOST_FQDN 2>/dev/null | grep -oP '^[a-z0-9.-]+$' || echo "")
if [ -z "$FQDN" ]; then
    echo "[postprovision] No HOST_FQDN — skipping redirect URI update"
    exit 0
fi

REDIRECT_URI="https://${FQDN}/.auth/login/aad/callback"
echo "[postprovision] Updating Easy Auth redirect URI: $REDIRECT_URI"

az ad app update --id "$AUTH_APP_ID" --web-redirect-uris "$REDIRECT_URI" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "[postprovision] Easy Auth redirect URI updated successfully"
else
    echo "[postprovision] WARNING: Failed to update redirect URI — login may not work until manually fixed"
fi
