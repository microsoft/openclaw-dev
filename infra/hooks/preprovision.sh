#!/bin/bash
# preprovision.sh — Creates the Entra ID app registration for the Azure Bot.
# Runs automatically before Bicep provisioning via azd hooks.
# Idempotent: skips creation if the app already exists in the azd env.
set -euo pipefail

ENV_NAME="${AZURE_ENV_NAME:-}"
echo "[preprovision] Creating bot app registration for environment: $ENV_NAME"

# Check if we already have a bot app ID saved
EXISTING_APP_ID=$(azd env get-value BOT_APP_ID 2>/dev/null | grep -oP '^[0-9a-f-]+$' || echo "")
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

# Create the service principal (enterprise application) for the bot app reg
# in this tenant. Without this, the Bot Framework token endpoint rejects
# the bot's appPassword with AADSTS7000229 ("missing service principal in
# the tenant"), which silently swallows every reply at activity-send time.
az ad sp create --id "$APP_ID" >/dev/null 2>&1 || true

# Save to azd env so Bicep can use them
azd env set BOT_APP_ID "$APP_ID"
azd env set BOT_APP_SECRET "$SECRET"
azd env set BOT_TENANT_ID "$TENANT_ID"

echo "[preprovision] Bot app registration created and saved to azd env"
echo "[preprovision]   App ID:    $APP_ID"
echo "[preprovision]   Tenant ID: $TENANT_ID"

# ---------------------------------------------------------------------------
# Easy Auth — Entra ID app registration for ACA built-in authentication
# Forces Microsoft login before any request reaches the container
# ---------------------------------------------------------------------------
EXISTING_AUTH_ID=$(azd env get-value EASYAUTH_APP_ID 2>/dev/null | grep -oP '^[0-9a-f-]+$' || echo "")
if [ -n "$EXISTING_AUTH_ID" ]; then
    echo "[preprovision] Easy Auth app registration already exists: $EXISTING_AUTH_ID"
else
    AUTH_APP_NAME="openclaw-auth-${ENV_NAME}"
    echo "[preprovision] Creating Easy Auth app registration: $AUTH_APP_NAME"

    # Create with placeholder redirect URI (updated after Bicep creates the container app)
    AUTH_APP_ID=$(az ad app create \
        --display-name "$AUTH_APP_NAME" \
        --sign-in-audience "AzureADMyOrg" \
        --web-redirect-uris "https://placeholder.azurecontainerapps.io/.auth/login/aad/callback" \
        --enable-id-token-issuance true \
        --query appId -o tsv 2>/dev/null)

    if [ -z "$AUTH_APP_ID" ]; then
        echo "[preprovision] ERROR: Failed to create Easy Auth app registration"
        exit 1
    fi

    azd env set EASYAUTH_APP_ID "$AUTH_APP_ID"
    echo "[preprovision] Easy Auth app ID: $AUTH_APP_ID"
fi
