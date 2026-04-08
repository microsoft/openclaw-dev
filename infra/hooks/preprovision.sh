#!/bin/bash
# preprovision.sh — Creates the Entra ID app registration for the Azure Bot.
# Runs automatically before Bicep provisioning via azd hooks.
# Idempotent: skips creation if the app already exists in the azd env.
set -euo pipefail

ENV_NAME="${AZURE_ENV_NAME:-}"
echo "[preprovision] Creating bot app registration for environment: $ENV_NAME"

# Check if we already have a bot app ID saved
EXISTING_APP_ID=$(azd env get-value BOT_APP_ID 2>/dev/null || echo "")
if [ -n "$EXISTING_APP_ID" ]; then
    echo "[preprovision] Bot app registration already exists: $EXISTING_APP_ID"
    exit 0
fi

# Create the Entra ID app registration
APP_NAME="openclaw-bot-${ENV_NAME}"
echo "[preprovision] Creating app registration: $APP_NAME"

APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --query appId -o tsv 2>/dev/null)

if [ -z "$APP_ID" ]; then
    echo "[preprovision] ERROR: Failed to create app registration"
    exit 1
fi

echo "[preprovision] App ID: $APP_ID"

# Create a client secret (valid 2 years)
SECRET=$(az ad app credential reset \
    --id "$APP_ID" \
    --years 2 \
    --query password -o tsv 2>/dev/null)

if [ -z "$SECRET" ]; then
    echo "[preprovision] ERROR: Failed to create client secret"
    exit 1
fi

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null)

# Save to azd env so Bicep can use them
azd env set BOT_APP_ID "$APP_ID"
azd env set BOT_APP_SECRET "$SECRET"
azd env set BOT_TENANT_ID "$TENANT_ID"

echo "[preprovision] Bot app registration created and saved to azd env"
echo "[preprovision]   App ID:    $APP_ID"
echo "[preprovision]   Tenant ID: $TENANT_ID"
