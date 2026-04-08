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

# Auto-fill password in control UI so users behind Easy Auth don't have to type it
CONTROL_UI="/usr/local/lib/node_modules/openclaw/dist/control-ui/index.html"
if [ -f "$CONTROL_UI" ]; then
    sed -i 's|</body>|<script>addEventListener("DOMContentLoaded",()=>{const i=setInterval(()=>{const inputs=document.querySelectorAll("input[type=password]");const p=inputs.length>=2?inputs[1]:null;if(p){p.value="passwordless-protection-with-easyauth";p.dispatchEvent(new Event("input",{bubbles:true}));clearInterval(i);setTimeout(()=>{const b=document.querySelector("button");if(b)b.click()},500)}},200);setTimeout(()=>clearInterval(i),10000)})</script></body>|' "$CONTROL_UI"
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
    exec openclaw gateway --bind lan --port 18789 --password "passwordless-protection-with-easyauth"
else
    echo "[openclaw] Using api-key"
    exec openclaw gateway --bind lan --port 18789 --password "passwordless-protection-with-easyauth"
fi
