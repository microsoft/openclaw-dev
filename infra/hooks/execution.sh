#!/usr/bin/env bash
# execution.sh — Execution layer bring-up (EXECUTION_MODE=sandbox).
# Builds the exec image + hash-gated disk image + warm snapshot, then injects
# the ids into the running Gateway so its sandbox MCP server can offload
# untrusted execution to ephemeral ACA Sandboxes. Best-effort.
set -uo pipefail
log() { echo "[execution] $*"; }
azdval() { local v; v="$(azd env get-value "$1" 2>/dev/null || true)"; case "$v" in *ERROR*|*"not found"*) v="";; esac; printf '%s' "$v"; }

MODE="$(printf '%s' "$(azdval EXECUTION_MODE)" | tr '[:upper:]' '[:lower:]')"
[ "$MODE" = "sandbox" ] || { log "EXECUTION_MODE != sandbox — nothing to do"; exit 0; }

if ! az account show -o none 2>/dev/null; then
    [ -n "${AZURE_CONFIG_DIR:-}" ] && unset AZURE_CONFIG_DIR
fi
if ! az account show -o none 2>/dev/null; then log "WARNING: az not authenticated — skipping"; exit 0; fi

SUB="$(azdval AZURE_SUBSCRIPTION_ID)"
RG="$(azdval AZURE_RESOURCE_GROUP)"; [ -z "$RG" ] && RG="rg-${AZURE_ENV_NAME:-}"
REGION="$(azdval AZURE_LOCATION)"
GROUP="$(azdval AZURE_SANDBOX_GROUP_NAME)"
ACR_NAME="$(azdval AZURE_CONTAINER_REGISTRY_NAME)"
WORKER="$(azdval WORKER_IDENTITY_CLIENT_ID)"
[ -n "$GROUP" ] && [ -n "$ACR_NAME" ] || { log "group/ACR not in env — skipping"; exit 0; }
log "Group=$GROUP ACR=$ACR_NAME Region=$REGION Worker=$WORKER"

if ! aca --version >/dev/null 2>&1; then
    curl -fsSL https://aka.ms/aca-cli-install | sh || true
    export PATH="$HOME/.aca/bin:$PATH"
fi
aca --version >/dev/null 2>&1 || { log "WARNING: aca CLI not available — skipping"; exit 0; }

PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [ -n "$PRINCIPAL_ID" ]; then
    aca sandboxgroup role create --group "$GROUP" -g "$RG" -s "$SUB" --region "$REGION" \
        --role "Container Apps SandboxGroup Data Owner" --principal-id "$PRINCIPAL_ID" >/dev/null 2>&1 || true
fi

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { log "WARNING: python not found — skipping provision"; exit 0; }
export AZURE_SUBSCRIPTION_ID="$SUB" AZURE_RESOURCE_GROUP="$RG" AZURE_SANDBOX_GROUP_NAME="$GROUP" \
       AZURE_LOCATION="$REGION" AZURE_CONTAINER_REGISTRY_NAME="$ACR_NAME" SANDBOX_DRIVER="cli" STARTUP="snapshot"

SRC_DIR="$(cd "$(dirname "$0")/../../src" && pwd)"
log "building execution image + disk + snapshot (this can take a few minutes)..."
PROV_OUT="$(cd "$SRC_DIR" && "$PY" -m sandbox_mcp.provision 2>&1)"
echo "$PROV_OUT" | sed 's/^/  /'

EXEC_ACR_IMAGE="$(printf '%s\n' "$PROV_OUT" | sed -n 's/^EXEC_ACR_IMAGE=//p' | tail -1)"
EXEC_IMAGE_DIGEST="$(printf '%s\n' "$PROV_OUT" | sed -n 's/^EXEC_IMAGE_DIGEST=//p' | tail -1)"
EXEC_DISK_ID="$(printf '%s\n' "$PROV_OUT" | sed -n 's/^EXEC_DISK_ID=//p' | tail -1)"
EXEC_SNAPSHOT="$(printf '%s\n' "$PROV_OUT" | sed -n 's/^EXEC_SNAPSHOT=//p' | tail -1)"
[ -n "$EXEC_DISK_ID" ] || { log "WARNING: provision produced no disk image id — see output above"; exit 0; }

[ -n "$EXEC_ACR_IMAGE" ] && azd env set EXEC_ACR_IMAGE "$EXEC_ACR_IMAGE" >/dev/null 2>&1 || true
[ -n "$EXEC_IMAGE_DIGEST" ] && azd env set EXEC_IMAGE_DIGEST "$EXEC_IMAGE_DIGEST" >/dev/null 2>&1 || true
[ -n "$EXEC_DISK_ID" ] && azd env set EXEC_DISK_ID "$EXEC_DISK_ID" >/dev/null 2>&1 || true
[ -n "$EXEC_SNAPSHOT" ] && azd env set EXEC_SNAPSHOT "$EXEC_SNAPSHOT" >/dev/null 2>&1 || true
[ -n "$WORKER" ] && azd env set WORKER_IDENTITY_CLIENT_ID "$WORKER" >/dev/null 2>&1 || true

APP="$(az containerapp list -g "$RG" --query "[?tags.\"azd-service-name\"=='openclaw'].name | [0]" -o tsv 2>/dev/null || true)"
[ -z "$APP" ] && APP="$(az containerapp list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)"
if [ -n "$APP" ]; then
    log "injecting EXEC_* env into container app '$APP'..."
    SET_VARS=("EXECUTION_MODE=sandbox")
    [ -n "$EXEC_ACR_IMAGE" ] && SET_VARS+=("EXEC_ACR_IMAGE=$EXEC_ACR_IMAGE")
    [ -n "$EXEC_IMAGE_DIGEST" ] && SET_VARS+=("EXEC_IMAGE_DIGEST=$EXEC_IMAGE_DIGEST")
    [ -n "$EXEC_DISK_ID" ] && SET_VARS+=("EXEC_DISK_ID=$EXEC_DISK_ID")
    [ -n "$EXEC_SNAPSHOT" ] && SET_VARS+=("EXEC_SNAPSHOT=$EXEC_SNAPSHOT")
    [ -n "$WORKER" ] && SET_VARS+=("WORKER_IDENTITY_CLIENT_ID=$WORKER")
    az containerapp update -g "$RG" -n "$APP" --set-env-vars "${SET_VARS[@]}" -o none 2>/dev/null || true
    log "Gateway updated. Sandbox execution is live."
else
    log "No container app yet — values persisted to azd env for the next provision."
fi
exit 0
