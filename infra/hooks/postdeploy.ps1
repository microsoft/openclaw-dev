# postdeploy.ps1 — Flip ACA ingress target port from :80 (placeholder image
# default) to :18789 (OpenClaw gateway) after the first real `azd deploy`.
# Idempotent: if ingress is already on :18789 it is a no-op.
$ErrorActionPreference = "Stop"

$rg = "rg-$env:AZURE_ENV_NAME"
$appName = az containerapp list -g $rg --query "[?tags.""azd-service-name""=='openclaw'].name | [0]" -o tsv 2>$null
if (-not $appName) {
    Write-Host "[postdeploy] No openclaw container app found in $rg — skipping ingress port fix"
    exit 0
}

$currentPort = az containerapp ingress show -g $rg -n $appName --query targetPort -o tsv 2>$null
if ($currentPort -eq "18789") {
    Write-Host "[postdeploy] Ingress already targets :18789 — nothing to do"
    exit 0
}

Write-Host "[postdeploy] Updating ingress targetPort: $currentPort -> 18789"
az containerapp ingress update -g $rg -n $appName --target-port 18789 -o none
Write-Host "[postdeploy] Ingress updated. The app may take ~30s to settle on the new revision."
