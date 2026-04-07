#!/bin/bash
set -e

STATE_DIR="/mnt/state"
OPENCLAW_DIR="/root/.openclaw"

# -------------------------------------------------------
# Restore state from the Azure Files mount (if it exists)
# -------------------------------------------------------
restore_state() {
    echo "[openclaw] Restoring state from Azure Files..."

    for dir in credentials workspace sessions; do
        if [ -d "$STATE_DIR/$dir" ] && [ "$(ls -A "$STATE_DIR/$dir" 2>/dev/null)" ]; then
            mkdir -p "$OPENCLAW_DIR/$dir"
            cp -r "$STATE_DIR/$dir/"* "$OPENCLAW_DIR/$dir/" 2>/dev/null || true
            echo "[openclaw]   restored $dir"
        fi
    done

    echo "[openclaw] State restoration complete."
}

# -------------------------------------------------------
# Save state back to the Azure Files mount on termination
# -------------------------------------------------------
save_state() {
    echo "[openclaw] Saving state to Azure Files..."

    for dir in credentials workspace sessions; do
        mkdir -p "$STATE_DIR/$dir"
        if [ -d "$OPENCLAW_DIR/$dir" ]; then
            cp -r "$OPENCLAW_DIR/$dir/"* "$STATE_DIR/$dir/" 2>/dev/null || true
        fi
    done

    echo "[openclaw] State saved."
}

# Trap SIGTERM/SIGINT to persist state before the container exits
trap 'save_state; exit 0' SIGTERM SIGINT

restore_state

# -------------------------------------------------------
# Start OpenClaw gateway
# OPENAI_BASE_URL is set by the Container App env vars.
# When AZURE_OPENAI_AUTH=managed-identity, the token-refresh wrapper
# fetches an Entra ID bearer token via DefaultAzureCredential and
# passes it as OPENAI_API_KEY to the OpenClaw process. No API keys needed.
# -------------------------------------------------------
echo "[openclaw] Starting gateway on port 18789..."
echo "[openclaw] Azure OpenAI v1 endpoint: ${OPENAI_BASE_URL}"
echo "[openclaw] Auth mode: ${AZURE_OPENAI_AUTH:-api-key}"

if [ "${AZURE_OPENAI_AUTH}" = "managed-identity" ]; then
    echo "[openclaw] Using managed identity (keyless) auth"
    node /opt/openclaw-auth/token-refresh.mjs --port 18789 &
else
    openclaw gateway --port 18789 &
fi
OPENCLAW_PID=$!

wait $OPENCLAW_PID
save_state
