#!/bin/bash
# postdeploy.sh — Flip ACA ingress target port from :80 (placeholder image
# default) to :18789 (OpenClaw gateway) after the first real `azd deploy`.
# Idempotent: if ingress is already on :18789 it is a no-op.
set -euo pipefail

RG="rg-${AZURE_ENV_NAME:-}"
APP_NAME=$(az containerapp list -g "$RG" --query "[?tags.\"azd-service-name\"=='openclaw'].name | [0]" -o tsv 2>/dev/null || true)
if [ -z "$APP_NAME" ]; then
    echo "[postdeploy] No openclaw container app found in $RG — skipping ingress port fix"
    exit 0
fi

CURRENT_PORT=$(az containerapp ingress show -g "$RG" -n "$APP_NAME" --query targetPort -o tsv 2>/dev/null || echo "")
if [ "$CURRENT_PORT" = "18789" ]; then
    echo "[postdeploy] Ingress already targets :18789 — nothing to do"
    exit 0
fi

echo "[postdeploy] Updating ingress targetPort: $CURRENT_PORT -> 18789"
az containerapp ingress update -g "$RG" -n "$APP_NAME" --target-port 18789 -o none
echo "[postdeploy] Ingress updated. The app may take ~30s to settle on the new revision."
