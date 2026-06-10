#!/bin/bash
# postdeploy.sh — Post-deploy fixups that tolerate partial prior deploys:
#   1. Scale container app from 0 to 1 after first deploy (no placeholder pull)
#   2. Flip ACA ingress target port from :80 (placeholder) to :18789 (OpenClaw gateway)
#   3. Update Easy Auth redirect URI if it still points to placeholder
#   4. Persist AZURE_CONTAINER_REGISTRY_ENDPOINT if missing from azd env
set -euo pipefail

# Ensure az CLI is authenticated (azd hooks use a repo-local config dir)
if ! az account show -o none >/dev/null 2>&1; then
    if [ -n "${AZURE_CONFIG_DIR:-}" ]; then
        unset AZURE_CONFIG_DIR
    fi
    if ! az account show -o none >/dev/null 2>&1; then
        echo "[postdeploy] WARNING: az not authenticated — skipping post-deploy fixups"
        exit 0
    fi
fi

# Resolve resource group from azd env (don't assume naming convention)
RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
if [ -z "$RG" ]; then RG="rg-${AZURE_ENV_NAME:-}"; fi

APP_NAME=$(az containerapp list -g "$RG" --query "[?tags.\"azd-service-name\"=='openclaw'].name | [0]" -o tsv 2>/dev/null || true)
if [ -z "$APP_NAME" ]; then
    echo "[postdeploy] No openclaw container app found in $RG — skipping"
    exit 0
fi

# --- Fix 1: Ensure container app is scaled up ---
# On first deploy, Bicep creates the app at scale 0 (no placeholder image pull).
# After the real image is deployed, scale to 1 so the app actually starts.
CURRENT_MIN=$(az containerapp show -g "$RG" -n "$APP_NAME" --query "properties.template.scale.minReplicas" -o tsv 2>/dev/null || echo "")
if [ "$CURRENT_MIN" = "0" ]; then
    echo "[postdeploy] Scaling container app from 0 to 1 replica..."
    az containerapp update -g "$RG" -n "$APP_NAME" --min-replicas 1 --max-replicas 1 -o none 2>/dev/null
    echo "[postdeploy] Container app scaled up."
else
    echo "[postdeploy] Container app already scaled ($CURRENT_MIN replicas)"
fi

# --- Fix 2: Ingress port ---
CURRENT_PORT=$(az containerapp ingress show -g "$RG" -n "$APP_NAME" --query targetPort -o tsv 2>/dev/null || echo "")
if [ "$CURRENT_PORT" = "18789" ]; then
    echo "[postdeploy] Ingress already targets :18789 — nothing to do"
else
    echo "[postdeploy] Updating ingress targetPort: $CURRENT_PORT -> 18789"
    az containerapp ingress update -g "$RG" -n "$APP_NAME" --target-port 18789 -o none
    echo "[postdeploy] Ingress updated. The app may take ~30s to settle on the new revision."
fi

# --- Fix 2: Easy Auth redirect URI ---
AUTH_APP_ID=$(azd env get-value EASYAUTH_APP_ID 2>/dev/null || echo "")
if [ -n "$AUTH_APP_ID" ]; then
    FQDN=$(az containerapp show -g "$RG" -n "$APP_NAME" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")
    if [ -n "$FQDN" ]; then
        REDIRECT_URI="https://$FQDN/.auth/login/aad/callback"
        CURRENT_URIS=$(az ad app show --id "$AUTH_APP_ID" --query "web.redirectUris" -o tsv 2>/dev/null || echo "")
        if echo "$CURRENT_URIS" | grep -qF "$REDIRECT_URI"; then
            echo "[postdeploy] Easy Auth redirect URI already correct"
        else
            echo "[postdeploy] Updating Easy Auth redirect URI: $REDIRECT_URI"
            az ad app update --id "$AUTH_APP_ID" --web-redirect-uris "$REDIRECT_URI" 2>/dev/null && \
                echo "[postdeploy] Easy Auth redirect URI updated successfully" || \
                echo "[postdeploy] WARNING: Failed to update redirect URI — login may need manual fix"
        fi
    fi
fi

# --- Fix 3: Ensure AZURE_CONTAINER_REGISTRY_ENDPOINT is in azd env ---
ACR_ENDPOINT=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>/dev/null || echo "")
if [ -z "$ACR_ENDPOINT" ]; then
    ACR_ENDPOINT=$(az acr list -g "$RG" --query "[0].loginServer" -o tsv 2>/dev/null || echo "")
    if [ -n "$ACR_ENDPOINT" ]; then
        azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "$ACR_ENDPOINT"
        echo "[postdeploy] Persisted AZURE_CONTAINER_REGISTRY_ENDPOINT=$ACR_ENDPOINT"
    fi
fi
