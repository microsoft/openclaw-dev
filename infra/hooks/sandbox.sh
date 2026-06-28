#!/usr/bin/env bash
# sandbox.sh — ACA Sandboxes host bring-up (USE_SANDBOX=true).
#
# Runs after `azd provision` (invoked from postprovision.sh). Bicep has already
# created the sandbox group (Microsoft.App/SandboxGroups), a user-assigned
# managed identity attached to it, ACR, and the AcrPull + Cognitive Services
# User role assignments. This script drives the ADC *data plane* via the `aca`
# CLI to build the OpenClaw image into ACR, import it as a private disk image,
# boot a sandbox with the keyless-OpenAI env contract, start the gateway, and
# expose its port. Best-effort: the postprovision hook is continueOnError.
set -uo pipefail

log() { echo "[sandbox] $*"; }

azdval() {
    local v
    v="$(azd env get-value "$1" 2>/dev/null || true)"
    case "$v" in *ERROR*|*"not found"*) v="";; esac
    printf '%s' "$v"
}

# Parse a top-level JSON field; prefer jq, fall back to python3.
json_get() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r "(if type==\"array\" then .[0] else . end).${field} // empty"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys,json
d=json.load(sys.stdin)
d=d[0] if isinstance(d,list) and d else d
print((d or {}).get('${field}','') if isinstance(d,dict) else '')"
    else
        # Last-resort regex; good enough for flat string values.
        grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
    fi
}

# --- Ensure az CLI is authenticated ---
if ! az account show -o none 2>/dev/null; then
    if [ -n "${AZURE_CONFIG_DIR:-}" ]; then
        log "az not authenticated in AZURE_CONFIG_DIR — falling back to default config dir"
        unset AZURE_CONFIG_DIR
    fi
fi
if ! az account show -o none 2>/dev/null; then
    log "WARNING: az not authenticated — skipping sandbox bring-up"
    exit 0
fi

# --- Resolve configuration from the azd environment ---
SUB="$(azdval AZURE_SUBSCRIPTION_ID)"
RG="$(azdval AZURE_RESOURCE_GROUP)"; [ -z "$RG" ] && RG="rg-${AZURE_ENV_NAME:-}"
REGION="$(azdval AZURE_LOCATION)"
GROUP="$(azdval AZURE_SANDBOX_GROUP_NAME)"
ACR_NAME="$(azdval AZURE_CONTAINER_REGISTRY_NAME)"
ACR_SERVER="$(azdval AZURE_CONTAINER_REGISTRY_ENDPOINT)"
OPENAI_BASE="$(azdval AZURE_OPENAI_ENDPOINT)"
DEPLOYMENT="$(azdval AZURE_AI_MODEL_DEPLOYMENT_NAME)"
MI_CLIENT_ID="$(azdval AZURE_SANDBOX_IDENTITY_CLIENT_ID)"
PORT="$(azdval SANDBOX_PORT)"; [ -z "$PORT" ] && PORT="18789"
PUBLIC_MODE="false"
[ "$(printf '%s' "$(azdval SANDBOX_PUBLIC)" | tr '[:upper:]' '[:lower:]')" = "true" ] && PUBLIC_MODE="true"
ALLOW_DOMAIN="false"
[ "$(printf '%s' "$(azdval SANDBOX_ALLOW_DOMAIN)" | tr '[:upper:]' '[:lower:]')" = "true" ] && ALLOW_DOMAIN="true"
# Transient per-invocation flags (process env, not azd env): `devclaw clone`
# sets both to reuse the latest disk image and boot an extra, additive instance.
REUSE_DISK="false"
[ "$(printf '%s' "${SANDBOX_REUSE_DISK:-}" | tr '[:upper:]' '[:lower:]')" = "true" ] && REUSE_DISK="true"
CLONE_MODE="false"
[ "$(printf '%s' "${SANDBOX_CLONE:-}" | tr '[:upper:]' '[:lower:]')" = "true" ] && CLONE_MODE="true"

if [ -z "$GROUP" ]; then
    log "No AZURE_SANDBOX_GROUP_NAME in env — was provisioning run with USE_SANDBOX=true? Skipping."
    exit 0
fi
[ -z "$ACR_NAME" ] && ACR_NAME="$(az acr list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)"
[ -z "$ACR_SERVER" ] && [ -n "$ACR_NAME" ] && ACR_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv 2>/dev/null || true)"

log "Group=$GROUP  RG=$RG  Region=$REGION  ACR=$ACR_SERVER"

# --- Ensure the `aca` CLI is installed ---
if ! aca --version >/dev/null 2>&1; then
    log "Installing the aca CLI (https://aka.ms/aca-cli-install)..."
    curl -fsSL https://aka.ms/aca-cli-install | sh || log "WARNING: automatic aca CLI install failed"
fi
if ! aca --version >/dev/null 2>&1; then
    log "WARNING: aca CLI not available. Install it (https://aka.ms/aca-cli-install) and re-run 'devclaw up'."
    log "The sandbox group '$GROUP' is already provisioned; only the data-plane bring-up was skipped."
    exit 0
fi

# --- Point the aca CLI at this group/subscription/region ---
[ -n "$SUB" ] && aca config set -s "$SUB" -g "$RG" --sandbox-group "$GROUP" --region "$REGION" >/dev/null 2>&1 || true
aca config sandbox set --group "$GROUP" --region "$REGION" >/dev/null 2>&1 || true

# --- Grant the deploying principal data-plane access (idempotent) ---
PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [ -n "$PRINCIPAL_ID" ]; then
    log "Ensuring 'Container Apps SandboxGroup Data Owner' for the deployer..."
    aca sandboxgroup role create --group "$GROUP" \
        --role "Container Apps SandboxGroup Data Owner" \
        --principal-id "$PRINCIPAL_ID" >/dev/null 2>&1 || true
fi
aca doctor >/dev/null 2>&1 || true

# --- Resolve the disk image: reuse the latest (clone) or build a fresh one ---
DISK_ID=""
if [ "$REUSE_DISK" = "true" ]; then
    log "Reusing the latest existing disk image (no rebuild)..."
    DISKS_JSON="$(aca sandboxgroup disk list --group "$GROUP" -o json 2>/dev/null || true)"
    if command -v jq >/dev/null 2>&1; then
        DISK_ID="$(printf '%s' "$DISKS_JSON" | jq -r 'sort_by(.status.createdAt) | last | .id // empty')"
    else
        DISK_ID="$(printf '%s' "$DISKS_JSON" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)"
    fi
    if [ -z "$DISK_ID" ]; then
        log "No existing disk image in the group. Run 'devclaw up' first to build one."
        exit 0
    fi
    log "Reusing disk image id: $DISK_ID"
else
    # Build the OpenClaw image into ACR (passwordless remote build).
    TAG="sandbox-$(date +%s)"
    IMAGE="openclaw:$TAG"
    SRC_DIR="$(cd "$(dirname "$0")/../../src" && pwd)"
    log "Building $IMAGE into $ACR_NAME via 'az acr build'..."
    if ! az acr build --registry "$ACR_NAME" --image "$IMAGE" --file "$SRC_DIR/Dockerfile" "$SRC_DIR"; then
        log "WARNING: image build failed. If this is a Docker Hub rate limit, set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN and re-run."
        exit 0
    fi
    IMAGE_REF="$ACR_SERVER/$IMAGE"
    # Import the ACR image as a private disk image. Managed-identity ACR pull
    # (--identity) returns 401 during the preview (needs a feature flag), so use
    # a short-lived AAD ACR token instead — still passwordless (no admin creds).
    # The username is the well-known ACR token GUID.
    DISK_NAME="openclaw-$TAG"
    log "Importing disk image '$DISK_NAME' from $IMAGE_REF..."
    ACR_TOKEN="$(az acr login -n "$ACR_NAME" --expose-token --query accessToken -o tsv 2>/dev/null || true)"
    if [ -z "$ACR_TOKEN" ]; then
        log "WARNING: could not obtain an ACR token ('az acr login --expose-token'). Skipping."
        exit 0
    fi
    DISK_JSON="$(aca sandboxgroup disk create --group "$GROUP" --image "$IMAGE_REF" --name "$DISK_NAME" \
        --username "00000000-0000-0000-0000-000000000000" --token "$ACR_TOKEN" -o json 2>/dev/null || true)"
    if [ -z "$DISK_JSON" ]; then
        log "WARNING: disk image import failed. Inspect 'aca sandboxgroup disk create --help'."
        exit 0
    fi
    DISK_ID="$(printf '%s' "$DISK_JSON" | json_get id)"
    log "Disk image id: $DISK_ID"
fi

# --- Boot the sandbox with the keyless-OpenAI env contract ---
# The disk image carries the container ENTRYPOINT (/opt/entrypoint.sh), which
# the sandbox runs automatically at boot using these --env values — it starts
# the gateway-proxy on 0.0.0.0:$PORT and the gateway on :18788. Do NOT exec the
# entrypoint manually afterward (it double-starts and trips the gateway lock).
GATEWAY_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
case "$OPENAI_BASE" in */) OPENAI_V1="${OPENAI_BASE}openai/v1/";; *) OPENAI_V1="${OPENAI_BASE}/openai/v1/";; esac
if [ "$CLONE_MODE" = "true" ]; then SBX_LABEL="openclaw-clone"; else SBX_LABEL="openclaw"; fi
log "Booting sandbox '$SBX_LABEL' from disk image..."
SBX_OUT="$(aca sandbox create --group "$GROUP" --disk-id "$DISK_ID" \
    --cpu 1000m --memory 2048Mi \
    --label name=$SBX_LABEL \
    --env "OPENAI_BASE_URL=$OPENAI_V1" \
    --env "OPENAI_MODEL_DEPLOYMENT=$DEPLOYMENT" \
    --env "AZURE_OPENAI_AUTH=managed-identity" \
    --env "AZURE_CLIENT_ID=$MI_CLIENT_ID" \
    --env "OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN" \
    -o json 2>&1 || true)"
# `sandbox create` prints human-readable status even with -o json, so parse the
# id from JSON when possible and fall back to the first UUID in the output.
SBX_ID="$(printf '%s' "$SBX_OUT" | json_get id)"
if [ -z "$SBX_ID" ]; then
    SBX_ID="$(printf '%s' "$SBX_OUT" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
fi
if [ -z "$SBX_ID" ]; then
    log "WARNING: sandbox create failed. Check 'aca doctor' and the Data Owner role assignment."
    exit 0
fi
log "Sandbox id: $SBX_ID"

# --- Wait for the auto-started gateway to come up, then expose the port ---
log "Waiting for the gateway to start inside the sandbox..."
sleep 20

# --- Expose the gateway port ---
# SANDBOX_PUBLIC=true → anonymous URL. Otherwise Entra-gate the port. The CLI
# only offers --email, which is brittle: guest/B2B sign-ins present a #EXT# UPN
# rather than the `mail` claim, so an exact email match can fail. Instead we
# POST a richer allow-list to the ADC data plane (`az rest`): the deployer's
# object id (the reliable `oid` claim) + email, plus the org email-domain
# suffix when SANDBOX_ALLOW_DOMAIN=true (lets any corporate login in).
add_anonymous_port() {
    aca sandbox port add --id "$SBX_ID" --port "$PORT" --anonymous -o json 2>/dev/null | json_get url
}
URL=""
if [ "$PUBLIC_MODE" = "true" ]; then
    log "Exposing port $PORT (anonymous — anyone with the URL can reach it; SANDBOX_PUBLIC=true)..."
    URL="$(add_anonymous_port)"
else
    OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
    MAIL="$(az ad signed-in-user show --query mail -o tsv 2>/dev/null || true)"
    # Build the entraId allow-list JSON.
    ENTRA="\"enabled\":true"
    [ -n "$OID" ] && ENTRA="$ENTRA,\"objectIds\":[\"$OID\"]"
    DOMAIN=""
    case "$MAIL" in
        *@*.*) DOMAIN="${MAIL#*@}"; ENTRA="$ENTRA,\"emails\":[\"$MAIL\"]"
               [ "$ALLOW_DOMAIN" = "true" ] && ENTRA="$ENTRA,\"emailSuffixes\":[\"@$DOMAIN\"]" ;;
    esac
    if [ -z "$OID" ] && [ -z "$MAIL" ]; then
        log "Could not resolve the deployer identity — exposing port $PORT anonymously."
        URL="$(add_anonymous_port)"
    else
        if [ "$ALLOW_DOMAIN" = "true" ] && [ -n "$DOMAIN" ]; then
            log "Exposing port $PORT (Entra-gated to any @$DOMAIN login + you; set SANDBOX_PUBLIC=true for an anonymous URL)..."
        else
            log "Exposing port $PORT (Entra-gated to the deployer; set SANDBOX_PUBLIC=true for an anonymous URL)..."
        fi
        TMP="$(mktemp 2>/dev/null || echo "/tmp/sbxport-$$.json")"
        printf '{"port":%s,"auth":{"entraId":{%s}}}' "$PORT" "$ENTRA" > "$TMP"
        URI="https://management.$REGION.azuredevcompute.io/subscriptions/$SUB/resourceGroups/$RG/sandboxGroups/$GROUP/sandboxes/$SBX_ID/ports/add?api-version=2026-02-01-preview"
        RESP="$(az rest --method post --url "$URI" --resource "https://dynamicsessions.io" --headers "Content-Type=application/json" --body "@$TMP" 2>/dev/null || true)"
        rm -f "$TMP"
        if [ -n "$RESP" ]; then
            if command -v jq >/dev/null 2>&1; then
                URL="$(printf '%s' "$RESP" | jq -r '.ports[0].url // empty')"
            else
                URL="$(printf '%s' "$RESP" | json_get url)"
            fi
        fi
        if [ -z "$URL" ]; then
            log "WARNING: Entra-gated port add failed — falling back to anonymous."
            URL="$(add_anonymous_port)"
        fi
    fi
fi

# --- Clone mode: additive extra instance — print it, don't touch primary env ---
if [ "$CLONE_MODE" = "true" ]; then
    echo ""
    log "OpenClaw CLONE is up (reused the existing image — no rebuild)."
    if [ -n "$URL" ]; then
        log "  URL:   ${URL}#token=${GATEWAY_TOKEN}"
        [ "$PUBLIC_MODE" != "true" ] && log "  Access: Entra-gated — sign in with the deploying account."
    else
        log "  Port exposed, but no URL was returned. Run: aca sandbox port list --id $SBX_ID"
    fi
    log "  Sandbox: $SBX_ID"
    log "  Delete:  aca sandbox delete --id $SBX_ID --yes"
    echo ""
    exit 0
fi

# --- Persist outputs to the azd environment ---
azd env set AZURE_SANDBOX_ID "$SBX_ID" >/dev/null 2>&1 || true
azd env set OPENCLAW_GATEWAY_TOKEN "$GATEWAY_TOKEN" >/dev/null 2>&1 || true
if [ -n "$URL" ]; then
    azd env set SANDBOX_URL "$URL" >/dev/null 2>&1 || true
    HOST_ONLY="$(printf '%s' "$URL" | sed -E 's#^https?://([^/]+).*#\1#')"
    [ -n "$HOST_ONLY" ] && azd env set HOST_FQDN "$HOST_ONLY" >/dev/null 2>&1 || true
fi

echo ""
log "OpenClaw sandbox is up."
if [ -n "$URL" ]; then
    log "  URL:   ${URL}#token=${GATEWAY_TOKEN}"
    [ "$PUBLIC_MODE" != "true" ] && log "  Access: Entra-gated — sign in with the deploying account."
else
    log "  Port exposed, but no URL was returned. Run: aca sandbox port list --id $SBX_ID"
fi
log "  Shell: aca sandbox shell --id $SBX_ID"
echo ""
exit 0
