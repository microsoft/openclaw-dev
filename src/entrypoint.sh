#!/bin/bash
echo "[openclaw] Starting..."
echo "[openclaw] OpenClaw version: $(openclaw --version 2>&1)"
echo "[openclaw] Auth mode: ${AZURE_OPENAI_AUTH:-api-key}"
echo "[openclaw] OPENAI_BASE_URL: ${OPENAI_BASE_URL}"

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

# Gateway token for auth (used by both --token flag and SPA auto-connect)
GATEWAY_TOKEN="easyauth-auto-connect"

# Inject token into URL hash BEFORE any SPA scripts load
# The SPA reads #token=<value>, saves it to settings, and auto-connects
CONTROL_UI="/usr/local/lib/node_modules/openclaw/dist/control-ui/index.html"
if [ -f "$CONTROL_UI" ]; then
    sed -i "0,/<script>/s//<script>if(!location.hash.includes('token=')){location.hash='token=${GATEWAY_TOKEN}';}<\/script><script>/" "$CONTROL_UI"
    echo "[openclaw] Injected auto-connect token into control UI HTML"
fi

echo "[openclaw] Config: $(cat /root/.openclaw/openclaw.json)"

if [ "${AZURE_OPENAI_AUTH}" = "managed-identity" ]; then
    echo "[openclaw] Using managed identity — acquiring token..."
    # Acquire initial Entra ID token, retry up to 60s for IMDS availability
    # @azure/identity is installed in /opt/openclaw-auth/node_modules
    TOKEN=""
    for i in $(seq 1 12); do
        TOKEN=$(cd /opt/openclaw-auth && node -e "
            import('@azure/identity').then(async ({DefaultAzureCredential}) => {
                const cred = new DefaultAzureCredential();
                const token = await cred.getToken('https://cognitiveservices.azure.com/.default');
                process.stdout.write(token.token);
            }).catch(e => { process.stderr.write(e.message.split('\n')[0] + '\n'); process.exit(1); });
        " 2>/tmp/token-err.log)
        if [ $? -eq 0 ] && [ -n "$TOKEN" ]; then
            echo "[openclaw] Entra ID token acquired (${#TOKEN} chars)"
            export OPENAI_API_KEY="$TOKEN"
            break
        fi
        echo "[openclaw] Token attempt $i/12 failed: $(cat /tmp/token-err.log 2>/dev/null | head -1)"
        sleep 5
    done
    if [ -z "$OPENAI_API_KEY" ]; then
        echo "[openclaw] WARNING: Could not acquire token, starting gateway anyway"
        export OPENAI_API_KEY="pending-managed-identity-token"
    fi
    exec openclaw gateway --bind lan --port 18789 --token "$GATEWAY_TOKEN"
else
    echo "[openclaw] Using api-key"
    exec openclaw gateway --bind lan --port 18789 --token "$GATEWAY_TOKEN"
fi
