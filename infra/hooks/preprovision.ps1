# preprovision.ps1 — Creates Entra ID app registrations for Bot and Easy Auth.
# Runs automatically before Bicep provisioning via azd hooks.
# Idempotent: skips creation if the apps already exist in the azd env.
$ErrorActionPreference = "Stop"

$envName = $env:AZURE_ENV_NAME
Write-Host "[preprovision] Environment: $envName"

# Helper: get azd env value, return empty string if key doesn't exist
function Get-AzdValue($key) {
    $raw = azd env get-value $key 2>$null
    if ($raw -match '^[0-9a-fA-F-]{36}$') { return $raw.Trim() }
    return ""
}

# Helper: read a free-form azd env value (e.g. boolean flags), trimmed.
function Get-AzdFlag($key) {
    $raw = azd env get-value $key 2>$null
    if ($null -eq $raw) { return "" }
    return ([string]$raw).Trim()
}

# ---------------------------------------------------------------------------
# 1. Bot — Entra ID app registration for Azure Bot Service (OPT-IN)
#    Teams integration is off by default. Enable with:
#      azd env set ENABLE_TEAMS true
#    Then re-run `devclaw up`. Existing deployments that already have a
#    BOT_APP_ID continue to work without setting the flag.
# ---------------------------------------------------------------------------
$botAppId = Get-AzdValue "BOT_APP_ID"
$enableTeams = (Get-AzdFlag "ENABLE_TEAMS").ToLower() -eq "true"
if ($botAppId) {
    Write-Host "[preprovision] Bot app registration already exists: $botAppId"
} elseif (-not $enableTeams) {
    Write-Host "[preprovision] Teams integration not enabled — skipping bot app registration."
    Write-Host "[preprovision]   To enable Teams later: azd env set ENABLE_TEAMS true && devclaw up"
} else {
    $appName = "openclaw-bot-$envName"
    Write-Host "[preprovision] Creating bot app registration: $appName"

    $botAppId = az ad app create --display-name $appName --sign-in-audience "AzureADMyOrg" --query appId -o tsv 2>$null
    if (-not $botAppId) {
        Write-Host "[preprovision] ERROR: Failed to create bot app registration"
        exit 1
    }

    $secret = az ad app credential reset --id $botAppId --years 2 --query password -o tsv 2>$null
    if (-not $secret) {
        Write-Host "[preprovision] ERROR: Failed to create bot client secret"
        exit 1
    }

    $tenantId = az account show --query tenantId -o tsv 2>$null

    # Create the service principal (enterprise application) for the bot app reg
    # in this tenant. Without this, the Bot Framework token endpoint rejects
    # the bot's appPassword with AADSTS7000229 ("missing service principal in
    # the tenant"), which silently swallows every reply at activity-send time.
    az ad sp create --id $botAppId 2>$null | Out-Null

    azd env set BOT_APP_ID $botAppId
    azd env set BOT_APP_SECRET $secret
    azd env set BOT_TENANT_ID $tenantId

    Write-Host "[preprovision] Bot app created: $botAppId (tenant: $tenantId)"
}

# Brief pause to avoid Entra ID throttling between app registrations
Start-Sleep -Seconds 3

# ---------------------------------------------------------------------------
# 2. Easy Auth — Entra ID app registration for ACA built-in authentication
#    Forces Microsoft login before any request reaches the container
# ---------------------------------------------------------------------------
$easyAuthAppId = Get-AzdValue "EASYAUTH_APP_ID"
if ($easyAuthAppId) {
    Write-Host "[preprovision] Easy Auth app registration already exists: $easyAuthAppId"
} else {
    $authAppName = "openclaw-auth-$envName"
    Write-Host "[preprovision] Creating Easy Auth app registration: $authAppName"

    $easyAuthAppId = az ad app create --display-name $authAppName --sign-in-audience "AzureADMyOrg" `
        --web-redirect-uris "https://placeholder.azurecontainerapps.io/.auth/login/aad/callback" `
        --enable-id-token-issuance true `
        --query appId -o tsv 2>$null
    if (-not $easyAuthAppId) {
        Write-Host "[preprovision] Retrying Easy Auth app creation after 5s..."
        Start-Sleep -Seconds 5
        $easyAuthAppId = az ad app create --display-name $authAppName --sign-in-audience "AzureADMyOrg" `
            --web-redirect-uris "https://placeholder.azurecontainerapps.io/.auth/login/aad/callback" `
            --enable-id-token-issuance true `
            --query appId -o tsv 2>$null
    }
    if (-not $easyAuthAppId) {
        Write-Host "[preprovision] ERROR: Failed to create Easy Auth app registration"
        exit 1
    }

    azd env set EASYAUTH_APP_ID $easyAuthAppId
    Write-Host "[preprovision] Easy Auth app created: $easyAuthAppId"
}
