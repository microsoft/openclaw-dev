#!/bin/bash
# preprovision.sh — Creates Entra ID app registrations for Bot (opt-in) and Easy Auth.
# Runs automatically before Bicep provisioning via azd hooks.
# Idempotent: skips creation if the apps already exist in the azd env.
set -euo pipefail

ENV_NAME="${AZURE_ENV_NAME:-}"
echo "[preprovision] Environment: $ENV_NAME"

# azd points AZURE_CONFIG_DIR at a repo-local folder so it doesn't pollute the
# user's az CLI config. That same folder typically has no signed-in account,
# so `az` calls inside this hook fail with "Please run 'az login'". Probe
# `az account show`; if it fails, clear AZURE_CONFIG_DIR so the CLI falls back
# to its default (~/.azure) where the user's real credentials live.
if ! az account show -o none >/dev/null 2>&1; then
    if [ -n "${AZURE_CONFIG_DIR:-}" ]; then
        echo "[preprovision] az not authenticated in AZURE_CONFIG_DIR=$AZURE_CONFIG_DIR — falling back to default config dir"
        unset AZURE_CONFIG_DIR
    fi
    if ! az account show -o none >/dev/null 2>&1; then
        echo "[preprovision] ERROR: az still not authenticated. Run 'az login' and retry."
        exit 1
    fi
fi

# Read a free-form azd env value (returns empty string if unset).
azd_flag() {
    azd env get-value "$1" 2>/dev/null | tr -d '[:space:]' || true
}

# Some corporate tenants require a serviceManagementReference (an SMR GUID
# referencing a service catalogue / asset management record) on every new
# Entra ID app registration. When set, pass it through to `az ad app create`.
# Get the right GUID from your tenant admin, then:
#   azd env set SERVICE_MANAGEMENT_REFERENCE <guid>
SMR="$(azd_flag SERVICE_MANAGEMENT_REFERENCE)"
SMR_ARGS=()
if [ -n "$SMR" ]; then
    if [[ "$SMR" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        echo "[preprovision] Using serviceManagementReference: $SMR"
        SMR_ARGS=(--service-management-reference "$SMR")
    else
        echo "[preprovision] WARNING: SERVICE_MANAGEMENT_REFERENCE='$SMR' is not a GUID - ignoring."
        echo "[preprovision]   Set it to the service-tree GUID from your tenant admin: azd env set SERVICE_MANAGEMENT_REFERENCE <guid>"
    fi
fi

# ---------------------------------------------------------------------------
# 1. Bot — Entra ID app registration for Azure Bot Service (OPT-IN)
#    Teams integration is off by default. Enable with:
#      azd env set ENABLE_TEAMS true
#    Then re-run `devclaw up`. Existing deployments that already have a
#    BOT_APP_ID continue to work without setting the flag.
# ---------------------------------------------------------------------------
EXISTING_APP_ID=$(azd env get-value BOT_APP_ID 2>/dev/null | grep -oP '^[0-9a-f-]+$' || echo "")
ENABLE_TEAMS_FLAG="$(azd_flag ENABLE_TEAMS)"
if [ -n "$EXISTING_APP_ID" ]; then
    echo "[preprovision] Bot app registration already exists: $EXISTING_APP_ID"
elif [ "${ENABLE_TEAMS_FLAG,,}" != "true" ]; then
    echo "[preprovision] Teams integration not enabled — skipping bot app registration."
    echo "[preprovision]   To enable Teams later: azd env set ENABLE_TEAMS true && devclaw up"
else
    APP_NAME="openclaw-bot-${ENV_NAME}"
    echo "[preprovision] Creating app registration: $APP_NAME"

    APP_ID=$(az ad app create \
        --display-name "$APP_NAME" \
        --sign-in-audience "AzureADMyOrg" \
        ${SMR_ARGS[@]+"${SMR_ARGS[@]}"} \
        --query appId -o tsv 2>/dev/null)

    if [ -z "$APP_ID" ]; then
        echo "[preprovision] ERROR: Failed to create bot app registration"
        exit 1
    fi

    echo "[preprovision] App ID: $APP_ID"

    # Create a client secret (valid 2 years)
    SECRET=$(az ad app credential reset \
        --id "$APP_ID" \
        --years 2 \
        --query password -o tsv 2>/dev/null)

    if [ -z "$SECRET" ]; then
        echo "[preprovision] ERROR: Failed to create bot client secret"
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
fi

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
        ${SMR_ARGS[@]+"${SMR_ARGS[@]}"} \
        --query appId -o tsv 2>/dev/null)

    if [ -z "$AUTH_APP_ID" ]; then
        echo "[preprovision] ERROR: Failed to create Easy Auth app registration"
        exit 1
    fi

    azd env set EASYAUTH_APP_ID "$AUTH_APP_ID"
    echo "[preprovision] Easy Auth app ID: $AUTH_APP_ID"
fi
