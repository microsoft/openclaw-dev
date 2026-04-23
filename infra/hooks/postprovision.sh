#!/bin/bash
# postprovision.sh — Updates the Easy Auth app registration redirect URI
# with the actual host FQDN (only known after Bicep provisioning).
set -euo pipefail

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
