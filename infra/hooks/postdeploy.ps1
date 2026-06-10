# postdeploy.ps1 — Post-deploy fixups that tolerate partial prior deploys:
#   1. Scale container app from 0 to 1 after first deploy (no placeholder pull)
#   2. Flip ACA ingress target port from :80 (placeholder) to :18789 (OpenClaw gateway)
#   3. Update Easy Auth redirect URI if it still points to placeholder
$ErrorActionPreference = "Stop"

# Ensure az CLI is authenticated (azd hooks use a repo-local config dir)
$authOk = $false
try {
    & az account show -o none 2>$null
    if ($LASTEXITCODE -eq 0) { $authOk = $true }
} catch {}
if (-not $authOk -and $env:AZURE_CONFIG_DIR) {
    Write-Host "[postdeploy] az not authenticated in AZURE_CONFIG_DIR — falling back to default config dir"
    Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
    try {
        & az account show -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $authOk = $true }
    } catch {}
}
if (-not $authOk) {
    Write-Host "[postdeploy] WARNING: az not authenticated — skipping post-deploy fixups"
    exit 0
}

# Resolve resource group from azd env (don't assume naming convention)
$rg = (azd env get-value AZURE_RESOURCE_GROUP 2>$null)
if (-not $rg) { $rg = "rg-$env:AZURE_ENV_NAME" }

$appName = az containerapp list -g $rg --query "[?tags.\`"azd-service-name\`"=='openclaw'].name | [0]" -o tsv 2>$null
if (-not $appName) {
    # Fallback: try without tag filter
    $appName = az containerapp list -g $rg --query "[0].name" -o tsv 2>$null
}
if (-not $appName) {
    Write-Host "[postdeploy] No openclaw container app found in $rg — skipping"
    exit 0
}

# --- Fix 1: Ensure container app is scaled up ---
# On first deploy, Bicep creates the app at scale 0 (no placeholder image pull).
# After the real image is deployed, scale to 1 so the app actually starts.
$currentMin = az containerapp show -g $rg -n $appName --query "properties.template.scale.minReplicas" -o tsv 2>$null
if ($currentMin -eq "0") {
    Write-Host "[postdeploy] Scaling container app from 0 to 1 replica..."
    az containerapp update -g $rg -n $appName --min-replicas 1 --max-replicas 1 -o none 2>$null
    Write-Host "[postdeploy] Container app scaled up."
} else {
    Write-Host "[postdeploy] Container app already scaled ($currentMin replicas)"
}

# --- Fix 2: Ingress port ---
$currentPort = az containerapp ingress show -g $rg -n $appName --query targetPort -o tsv 2>$null
if ($currentPort -eq "18789") {
    Write-Host "[postdeploy] Ingress already targets :18789 — nothing to do"
} else {
    Write-Host "[postdeploy] Updating ingress targetPort: $currentPort -> 18789"
    az containerapp ingress update -g $rg -n $appName --target-port 18789 -o none
    Write-Host "[postdeploy] Ingress updated. The app may take ~30s to settle on the new revision."
}

# --- Fix 2: Easy Auth redirect URI ---
# If postprovision didn't run (partial deploy), the redirect URI is still
# the placeholder. Fix it here using the actual FQDN from the container app.
$authAppId = (azd env get-value EASYAUTH_APP_ID 2>$null) -replace '\s+ERROR:.*','' | Where-Object { $_ -match '^[0-9a-f-]+$' }
if ($authAppId) {
    $fqdn = az containerapp show -g $rg -n $appName --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
    if ($fqdn) {
        $redirectUri = "https://$fqdn/.auth/login/aad/callback"
        $currentUris = az ad app show --id $authAppId --query "web.redirectUris" -o json 2>$null | ConvertFrom-Json
        if ($currentUris -notcontains $redirectUri) {
            Write-Host "[postdeploy] Updating Easy Auth redirect URI: $redirectUri"
            az ad app update --id $authAppId --web-redirect-uris $redirectUri 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[postdeploy] Easy Auth redirect URI updated successfully"
            } else {
                Write-Host "[postdeploy] WARNING: Failed to update redirect URI — login may need manual fix"
            }
        } else {
            Write-Host "[postdeploy] Easy Auth redirect URI already correct"
        }
    }
}

# --- Fix 3: Ensure AZURE_CONTAINER_REGISTRY_ENDPOINT is in azd env ---
# On partial deploys, Bicep outputs may not have been saved. Look it up from
# the resource group so subsequent `azd deploy` calls don't fail.
$acrEndpoint = (azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>$null)
if (-not $acrEndpoint -or $acrEndpoint -match 'ERROR') {
    $acrEndpoint = az acr list -g $rg --query "[0].loginServer" -o tsv 2>$null
    if ($acrEndpoint) {
        azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT $acrEndpoint
        Write-Host "[postdeploy] Persisted AZURE_CONTAINER_REGISTRY_ENDPOINT=$acrEndpoint"
    }
}
