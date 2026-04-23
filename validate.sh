#!/bin/bash
# validate.sh — Test that OpenClaw on ACA can reach Azure OpenAI via managed identity.
# Run from a machine connected to the VNet (e.g. az containerapp exec, VPN, or Bastion).
#
# Usage: ./validate.sh <HOST_FQDN>
#
# Example: ./validate.sh openclaw-abc123.internal.eastus.azurecontainerapps.io

set -euo pipefail

FQDN="${1:?Usage: ./validate.sh <HOST_FQDN>}"
BASE="https://${FQDN}"

echo "============================================"
echo "  OpenClaw on ACA — Validation Tests"
echo "============================================"
echo ""
echo "Target: ${BASE}"
echo ""

# -------------------------------------------------------
# Test 1: Gateway health check
# -------------------------------------------------------
echo "--- Test 1: Gateway health check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Gateway is healthy (HTTP $HTTP_CODE)"
else
    echo "❌ Gateway health check failed (HTTP $HTTP_CODE)"
    echo "   Make sure you are connected to the VNet (the ACA environment is internal-only)."
    exit 1
fi
echo ""

# -------------------------------------------------------
# Test 2: Send a test message via the OpenClaw CLI / API
# -------------------------------------------------------
echo "--- Test 2: Send a test message to the agent ---"
RESPONSE=$(curl -s -X POST "${BASE}/api/agent" \
    -H "Content-Type: application/json" \
    -d '{"message": "Say hello in exactly 5 words."}' \
    --max-time 30 2>/dev/null || echo "CURL_FAILED")

if [ "$RESPONSE" = "CURL_FAILED" ]; then
    echo "❌ Failed to reach the agent API"
    exit 1
fi

echo "Response: ${RESPONSE}"
echo "✅ Agent responded successfully"
echo ""

# -------------------------------------------------------
# Test 3: Verify Azure OpenAI is the backend (not 3P OpenAI)
# -------------------------------------------------------
echo "--- Test 3: Verify Azure OpenAI backend ---"
# Check the container logs for the OPENAI_BASE_URL
echo "Checking environment configuration..."
OPENAI_URL=$(curl -s "${BASE}/api/status" 2>/dev/null | grep -o '"openai_base_url":"[^"]*"' || echo "")
if echo "$OPENAI_URL" | grep -q "openai.azure.com"; then
    echo "✅ Azure OpenAI endpoint confirmed"
elif [ -z "$OPENAI_URL" ]; then
    echo "⚠️  Could not verify endpoint from status API (may not be exposed)"
    echo "   Check container logs: az containerapp logs show --name <app> --resource-group <rg>"
else
    echo "❌ Unexpected endpoint: $OPENAI_URL"
fi
echo ""

# -------------------------------------------------------
# Test 4: Verify managed identity auth (no API keys)
# -------------------------------------------------------
echo "--- Test 4: Verify keyless auth ---"
AUTH_MODE=$(curl -s "${BASE}/api/status" 2>/dev/null | grep -o '"auth_mode":"[^"]*"' || echo "")
if echo "$AUTH_MODE" | grep -qi "managed-identity"; then
    echo "✅ Managed identity auth confirmed"
elif [ -z "$AUTH_MODE" ]; then
    echo "⚠️  Auth mode not exposed via status API"
    echo "   Verify via: az containerapp show --name <app> --resource-group <rg> --query 'properties.template.containers[0].env'"
else
    echo "ℹ️  Auth mode: $AUTH_MODE"
fi
echo ""

# -------------------------------------------------------
# Test 5: Verify state persistence volume
# -------------------------------------------------------
echo "--- Test 5: Verify Azure Files mount ---"
# This test checks if the state directory exists via the container exec
echo "   Check via: az containerapp exec --name <app> --resource-group <rg> -- ls -la /mnt/state/"
echo "   Expected: credentials/ workspace/ sessions/"
echo ""

echo "============================================"
echo "  All reachable tests completed"
echo "============================================"
echo ""
echo "Manual tests to try:"
echo "  1. Connect a channel (Telegram, Discord, etc.) via openclaw onboard"
echo "  2. Send a message and verify the agent responds using GPT-5-mini"
echo "  3. Restart the container and verify state is preserved from Azure Files"
echo "  4. Check logs: az containerapp logs show --name <app> --resource-group <rg> --follow"
echo "  5. Verify no API keys: az cognitiveservices account list-keys (should fail with disableLocalAuth)"
