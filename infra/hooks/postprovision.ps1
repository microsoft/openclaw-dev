# postprovision.ps1 — Updates the Easy Auth app registration redirect URI
# with the actual host FQDN (only known after Bicep provisioning).
$ErrorActionPreference = "Stop"

# Ensure az CLI is authenticated (azd hooks use a repo-local config dir)
$authOk = $false
try {
    & az account show -o none 2>$null
    if ($LASTEXITCODE -eq 0) { $authOk = $true }
} catch {}
if (-not $authOk -and $env:AZURE_CONFIG_DIR) {
    Write-Host "[postprovision] az not authenticated in AZURE_CONFIG_DIR — falling back to default config dir"
    Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
    try {
        & az account show -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $authOk = $true }
    } catch {}
}
if (-not $authOk) {
    Write-Host "[postprovision] WARNING: az not authenticated — skipping redirect URI update"
    exit 0
}

$authAppId = (azd env get-value EASYAUTH_APP_ID 2>$null) -replace '\s+ERROR:.*','' | Where-Object { $_ -match '^[0-9a-f-]+$' }
if (-not $authAppId) {
    Write-Host "[postprovision] No EASYAUTH_APP_ID — skipping redirect URI update"
    exit 0
}

$fqdn = (azd env get-value HOST_FQDN 2>$null) -replace '\s+ERROR:.*','' | Where-Object { $_ -match '\.' }
if (-not $fqdn) {
    Write-Host "[postprovision] No HOST_FQDN — skipping redirect URI update"
    exit 0
}

$redirectUri = "https://$fqdn/.auth/login/aad/callback"
Write-Host "[postprovision] Updating Easy Auth redirect URI: $redirectUri"

az ad app update --id $authAppId --web-redirect-uris $redirectUri 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[postprovision] Easy Auth redirect URI updated successfully"
} else {
    Write-Host "[postprovision] WARNING: Failed to update redirect URI — login may not work until manually fixed"
}
