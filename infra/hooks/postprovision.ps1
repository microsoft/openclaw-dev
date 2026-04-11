# postprovision.ps1 — Updates the Easy Auth app registration redirect URI
# with the actual Container App FQDN (only known after Bicep provisioning).
$ErrorActionPreference = "Stop"

$authAppId = azd env get-value EASYAUTH_APP_ID 2>$null
if (-not $authAppId) {
    Write-Host "[postprovision] No EASYAUTH_APP_ID — skipping redirect URI update"
    exit 0
}

$fqdn = azd env get-value CONTAINER_APP_FQDN 2>$null
if (-not $fqdn) {
    Write-Host "[postprovision] No CONTAINER_APP_FQDN — skipping redirect URI update"
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
