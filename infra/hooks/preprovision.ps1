# preprovision.ps1 — Creates the Entra ID app registration for the Azure Bot.
# Runs automatically before Bicep provisioning via azd hooks.
# Idempotent: skips creation if the app already exists in the azd env.
$ErrorActionPreference = "Stop"

$envName = $env:AZURE_ENV_NAME
Write-Host "[preprovision] Creating bot app registration for environment: $envName"

# Check if we already have a bot app ID saved
$existingAppId = azd env get-value BOT_APP_ID 2>$null
if ($existingAppId) {
    Write-Host "[preprovision] Bot app registration already exists: $existingAppId"
    exit 0
}

# Create the Entra ID app registration
$appName = "openclaw-bot-$envName"
Write-Host "[preprovision] Creating app registration: $appName"

$appId = az ad app create --display-name $appName --sign-in-audience "AzureADMyOrg" --query appId -o tsv 2>$null
if (-not $appId) {
    Write-Host "[preprovision] ERROR: Failed to create app registration"
    exit 1
}
Write-Host "[preprovision] App ID: $appId"

# Create a client secret (valid 2 years)
$secret = az ad app credential reset --id $appId --years 2 --query password -o tsv 2>$null
if (-not $secret) {
    Write-Host "[preprovision] ERROR: Failed to create client secret"
    exit 1
}

# Get tenant ID
$tenantId = az account show --query tenantId -o tsv 2>$null

# Save to azd env so Bicep can use them
azd env set BOT_APP_ID $appId
azd env set BOT_APP_SECRET $secret
azd env set BOT_TENANT_ID $tenantId

Write-Host "[preprovision] Bot app registration created and saved to azd env"
Write-Host "[preprovision]   App ID:    $appId"
Write-Host "[preprovision]   Tenant ID: $tenantId"

# ---------------------------------------------------------------------------
# Easy Auth — Entra ID app registration for ACA built-in authentication
# Forces Microsoft login before any request reaches the container
# ---------------------------------------------------------------------------
$existingAuthId = azd env get-value EASYAUTH_APP_ID 2>$null
if ($existingAuthId) {
    Write-Host "[preprovision] Easy Auth app registration already exists: $existingAuthId"
} else {
    $authAppName = "openclaw-auth-$envName"
    Write-Host "[preprovision] Creating Easy Auth app registration: $authAppName"

    # Create with placeholder redirect URI (updated after Bicep creates the container app)
    $authAppId = az ad app create --display-name $authAppName --sign-in-audience "AzureADMyOrg" `
        --web-redirect-uris "https://placeholder.azurecontainerapps.io/.auth/login/aad/callback" `
        --enable-id-token-issuance true `
        --query appId -o tsv 2>$null
    if (-not $authAppId) {
        Write-Host "[preprovision] ERROR: Failed to create Easy Auth app registration"
        exit 1
    }

    azd env set EASYAUTH_APP_ID $authAppId
    Write-Host "[preprovision] Easy Auth app ID: $authAppId"
}
