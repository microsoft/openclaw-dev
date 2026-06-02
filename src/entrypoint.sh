#!/bin/bash
echo "[openclaw] Starting..."
echo "[openclaw] OpenClaw version: $(openclaw --version 2>&1)"
echo "[openclaw] Auth mode: ${AZURE_OPENAI_AUTH:-api-key}"
echo "[openclaw] OPENAI_BASE_URL: ${OPENAI_BASE_URL}"

# When SKIP_STORAGE=true (Azure Policy blocks shared-key access on storage),
# /mnt/state is not mounted. Fall back to an in-container ephemeral path so
# the rest of the script (state restore + token persist) doesn't fail. State
# will not survive a replica restart in that mode — documented trade-off.
if [ ! -d /mnt/state ]; then
    echo "[openclaw] /mnt/state not mounted — using ephemeral /var/openclaw-state (no persistence across restarts)"
    mkdir -p /var/openclaw-state
    ln -sfn /var/openclaw-state /mnt/state
fi

# Restore state
for dir in credentials workspace sessions; do
    if [ -d "/mnt/state/$dir" ] && [ "$(ls -A /mnt/state/$dir 2>/dev/null)" ]; then
        mkdir -p "/root/.openclaw/$dir"
        cp -r "/mnt/state/$dir/"* "/root/.openclaw/$dir/" 2>/dev/null || true
    fi
done

# Canonical config (prevents stale config from Azure Files)
cp -f /opt/openclaw.json.canonical /root/.openclaw/openclaw.json

# Substitute env vars in config
sed -i "s|\${OPENAI_BASE_URL}|${OPENAI_BASE_URL}|g" /root/.openclaw/openclaw.json
sed -i "s|\${MSTEAMS_APP_ID}|${MSTEAMS_APP_ID}|g" /root/.openclaw/openclaw.json
sed -i "s|\${MSTEAMS_APP_PASSWORD}|${MSTEAMS_APP_PASSWORD}|g" /root/.openclaw/openclaw.json
sed -i "s|\${MSTEAMS_TENANT_ID}|${MSTEAMS_TENANT_ID}|g" /root/.openclaw/openclaw.json

# Teams is opt-in. When MSTEAMS_APP_ID is empty the deployment was provisioned
# without a Bot app registration (no `ENABLE_TEAMS=true`), so disable the
# msteams plugin in the canonical config to avoid noisy Bot Framework auth
# attempts against empty credentials.
if [ -z "${MSTEAMS_APP_ID:-}" ]; then
    echo "[openclaw] MSTEAMS_APP_ID not set — disabling msteams plugin (Teams opt-in)"
    node -e "const fs=require('fs');const p='/root/.openclaw/openclaw.json';const c=JSON.parse(fs.readFileSync(p,'utf8'));if(c.channels&&c.channels.msteams){c.channels.msteams.enabled=false;}if(c.plugins){c.plugins.allow=(c.plugins.allow||[]).filter(x=>x!=='msteams');if(c.plugins.entries&&c.plugins.entries.msteams){c.plugins.entries.msteams.enabled=false;}}fs.writeFileSync(p,JSON.stringify(c,null,2));"
fi

# Gateway token for auth (used by both --token flag and SPA auto-connect).
# Persist across container restarts via /mnt/state so the Control UI in the
# browser doesn't drift out of sync after every deploy. Precedence:
#   1. OPENCLAW_GATEWAY_TOKEN env var (if set)
#   2. Existing token on persistent volume
#   3. Generate fresh and persist
TOKEN_FILE="/mnt/state/gateway-token"
if [ -n "${OPENCLAW_GATEWAY_TOKEN}" ]; then
    GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
    echo "[openclaw] Using gateway token from env"
elif [ -s "$TOKEN_FILE" ]; then
    GATEWAY_TOKEN="$(cat "$TOKEN_FILE")"
    echo "[openclaw] Loaded persisted gateway token"
else
    GATEWAY_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    mkdir -p "$(dirname "$TOKEN_FILE")"
    printf '%s' "$GATEWAY_TOKEN" > "$TOKEN_FILE"
    echo "[openclaw] Generated and persisted new gateway token"
fi

# Inject token into URL hash BEFORE any SPA scripts load
# The SPA reads #token=<value>, saves it to settings, and auto-connects
CONTROL_UI="/usr/local/lib/node_modules/openclaw/dist/control-ui/index.html"
if [ -f "$CONTROL_UI" ]; then
    sed -i "0,/<script>/s//<script>if(!location.hash.includes('token=')){location.hash='token=${GATEWAY_TOKEN}';}<\/script><script>/" "$CONTROL_UI"
    echo "[openclaw] Injected auto-connect token into control UI HTML"
fi

echo "[openclaw] Config loaded (details redacted from logs)"

# -----------------------------------------------------------------------------
# Diagnostics: prove the msteams plugin was installed at build time and is
# discoverable at runtime. These are one-shot, fail-fast checks; their output
# is essential for debugging silent plugin-load failures in Teams setup.
# -----------------------------------------------------------------------------
echo "[openclaw] === Plugin install diagnostics ==="
if [ -d /root/.openclaw/npm/node_modules/@openclaw/msteams ]; then
    echo "[openclaw] @openclaw/msteams package: PRESENT at /root/.openclaw/npm/node_modules/@openclaw/msteams"
    if [ -f /root/.openclaw/npm/node_modules/@openclaw/msteams/package.json ]; then
        echo "[openclaw] msteams version: $(node -e "console.log(require('/root/.openclaw/npm/node_modules/@openclaw/msteams/package.json').version)" 2>/dev/null || echo unknown)"
    fi
else
    echo "[openclaw] @openclaw/msteams package: MISSING"
fi
if [ -f /root/.openclaw/plugins/installs.json ]; then
    echo "[openclaw] installs.json: PRESENT ($(wc -c < /root/.openclaw/plugins/installs.json) bytes)"
    echo "[openclaw] installs.json content:"
    cat /root/.openclaw/plugins/installs.json 2>&1 | sed 's/^/[openclaw installs]   /'
else
    echo "[openclaw] installs.json: MISSING"
fi
echo "[openclaw] env presence: MSTEAMS_APP_ID=$([ -n "$MSTEAMS_APP_ID" ] && echo "set(${#MSTEAMS_APP_ID}ch)" || echo MISSING); MSTEAMS_APP_PASSWORD=$([ -n "$MSTEAMS_APP_PASSWORD" ] && echo "set(${#MSTEAMS_APP_PASSWORD}ch)" || echo MISSING); MSTEAMS_TENANT_ID=$([ -n "$MSTEAMS_TENANT_ID" ] && echo "set(${#MSTEAMS_TENANT_ID}ch)" || echo MISSING)"
echo "[openclaw] openclaw.json channels.msteams section (secrets redacted):"
node -e "const fs=require('fs');const c=JSON.parse(fs.readFileSync('/root/.openclaw/openclaw.json','utf8'));const m=c.channels?.msteams ?? null;if(!m){console.log('  channels.msteams: MISSING');}else{const redacted={...m};if(redacted.appPassword)redacted.appPassword='[REDACTED '+redacted.appPassword.length+'ch]';console.log(JSON.stringify(redacted,null,2).replace(/^/gm,'  '));}" 2>&1 | sed 's/^/[openclaw config]   /'
echo "[openclaw] openclaw plugins list:"
openclaw plugins list 2>&1 | sed 's/^/[openclaw plugins]   /' || echo "[openclaw plugins]   (command failed)"
echo "[openclaw] === End diagnostics ==="

# -----------------------------------------------------------------------------
# Gateway proxy: terminates the public ACA ingress on :18789 and routes
#   POST /api/messages -> 127.0.0.1:3978  (msteams plugin's webhook)
#   *                  -> 127.0.0.1:18788 (openclaw gateway)
# The msteams plugin opens its own Express server on 3978; ACA only exposes one
# public port, so without this proxy Bot Framework can't reach /api/messages.
# Started before the gateway — returns 502 until upstreams come up, which
# Bot Framework retries. Always-on regardless of AOAI auth mode.
# -----------------------------------------------------------------------------
echo "[openclaw] Starting gateway-proxy on 0.0.0.0:18789 (routes /api/messages -> :3978, * -> :18788)"
GATEWAY_PROXY_PORT=18789 \
    GATEWAY_UPSTREAM=http://127.0.0.1:18788 \
    MSTEAMS_UPSTREAM=http://127.0.0.1:3978 \
    node /opt/openclaw-auth/gateway-proxy.mjs >/proc/1/fd/1 2>/proc/1/fd/2 &
GATEWAY_PROXY_PID=$!
echo "[openclaw] gateway-proxy pid=$GATEWAY_PROXY_PID"

if [ "${AZURE_OPENAI_AUTH}" = "managed-identity" ]; then
    echo "[openclaw] Using managed identity — starting auth-proxy on 127.0.0.1:18790"

    # Derive upstream AOAI host from OPENAI_BASE_URL (strip /openai/v1/ suffix)
    UPSTREAM="$(echo "${OPENAI_BASE_URL}" | sed -E 's|/openai/v1/?$||')"
    echo "[openclaw] auth-proxy upstream: $UPSTREAM"

    # Start the auth-proxy in background. It refreshes tokens transparently
    # via @azure/identity's getBearerTokenProvider (per-request, cached).
    AOAI_UPSTREAM_URL="$UPSTREAM" AUTH_PROXY_PORT=18790 \
        node /opt/openclaw-auth/auth-proxy.mjs >/proc/1/fd/1 2>/proc/1/fd/2 &
    PROXY_PID=$!
    echo "[openclaw] auth-proxy pid=$PROXY_PID"

    # Wait for proxy to be listening (max 10s)
    for i in $(seq 1 20); do
        if (echo > /dev/tcp/127.0.0.1/18790) 2>/dev/null; then
            echo "[openclaw] auth-proxy ready"
            break
        fi
        sleep 0.5
    done

    # Re-point OpenClaw at the proxy (preserves /openai/v1/ path semantics).
    # The proxy will inject a fresh bearer token on every request.
    export OPENAI_BASE_URL="http://127.0.0.1:18790/openai/v1/"
    sed -i "s|https://[^\"]*\.openai\.azure\.com/openai/v1/|http://127.0.0.1:18790/openai/v1/|g" /root/.openclaw/openclaw.json

    # OPENAI_API_KEY is required by the SDK but ignored by the proxy.
    export OPENAI_API_KEY="injected-by-auth-proxy"

    # Gateway runs on internal :18788 (the gateway-proxy fronts it on :18789).
    exec openclaw gateway --bind lan --port 18788 --token "$GATEWAY_TOKEN"
else
    echo "[openclaw] Using api-key"
    # Gateway runs on internal :18788 (the gateway-proxy fronts it on :18789).
    exec openclaw gateway --bind lan --port 18788 --token "$GATEWAY_TOKEN"
fi
