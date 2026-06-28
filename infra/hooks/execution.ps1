# execution.ps1 — Execution layer bring-up (EXECUTION_MODE=sandbox).
#
# The Gateway stays on ACA; this builds the execution image + hash-gated disk
# image + warm snapshot (via sandbox_mcp.provision), then injects the resulting
# ids into the running Gateway container so its sandbox MCP server can offload
# untrusted tool execution to ephemeral ACA Sandboxes.
#
# Idempotent + best-effort (postprovision is continueOnError).
$ErrorActionPreference = "Stop"

function Get-AzdValue([string]$Key) {
    $v = (azd env get-value $Key 2>$null)
    if (-not $v -or $v -match 'ERROR|not found') { return "" }
    return $v.Trim()
}

$mode = (Get-AzdValue EXECUTION_MODE).ToLower()
if ($mode -ne 'sandbox') {
    Write-Host "[execution] EXECUTION_MODE != sandbox — nothing to do"
    exit 0
}

# --- az auth (azd hooks use a repo-local config dir; fall back if needed) ---
$authOk = $false
try { & az account show -o none 2>$null; if ($LASTEXITCODE -eq 0) { $authOk = $true } } catch {}
if (-not $authOk -and $env:AZURE_CONFIG_DIR) {
    Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
    try { & az account show -o none 2>$null; if ($LASTEXITCODE -eq 0) { $authOk = $true } } catch {}
}
if (-not $authOk) { Write-Host "[execution] WARNING: az not authenticated — skipping"; exit 0 }

$sub     = Get-AzdValue AZURE_SUBSCRIPTION_ID
$rg      = Get-AzdValue AZURE_RESOURCE_GROUP
if (-not $rg) { $rg = "rg-$env:AZURE_ENV_NAME" }
$region  = Get-AzdValue AZURE_LOCATION
$group   = Get-AzdValue AZURE_SANDBOX_GROUP_NAME
$acrName = Get-AzdValue AZURE_CONTAINER_REGISTRY_NAME
$worker  = Get-AzdValue WORKER_IDENTITY_CLIENT_ID
if (-not $group -or -not $acrName) {
    Write-Host "[execution] sandbox group / ACR not in env — was provisioning run with EXECUTION_MODE=sandbox? Skipping."
    exit 0
}
Write-Host "[execution] Group=$group ACR=$acrName Region=$region Worker=$worker"

# --- aca CLI (install if missing) ---
$acaOk = $false
try { & aca --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $acaOk = $true } } catch {}
if (-not $acaOk) {
    try { Invoke-RestMethod https://aka.ms/aca-cli-install-ps | Invoke-Expression } catch {}
    foreach ($p in @("$env:USERPROFILE\.aca\bin", "$env:LOCALAPPDATA\Programs\aca")) {
        if (Test-Path (Join-Path $p 'aca.exe')) { $env:PATH = "$p;$env:PATH"; break }
    }
    try { & aca --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $acaOk = $true } } catch {}
}
if (-not $acaOk) { Write-Host "[execution] WARNING: aca CLI not available — skipping"; exit 0 }

# --- grant the deploying principal data-plane access (provision runs as deployer) ---
$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if ($principalId) {
    aca sandboxgroup role create --group $group -g $rg -s $sub --region $region `
        --role "Container Apps SandboxGroup Data Owner" --principal-id $principalId 2>$null | Out-Null
}

# --- build exec image + hash-gated disk image + warm snapshot ---
$py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $py) { Write-Host "[execution] WARNING: python not found — skipping provision"; exit 0 }
$env:AZURE_SUBSCRIPTION_ID = $sub
$env:AZURE_RESOURCE_GROUP = $rg
$env:AZURE_SANDBOX_GROUP_NAME = $group
$env:AZURE_LOCATION = $region
$env:AZURE_CONTAINER_REGISTRY_NAME = $acrName
$env:SANDBOX_DRIVER = "cli"
$env:STARTUP = "snapshot"

$srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) "..\src" | Resolve-Path
Write-Host "[execution] building execution image + disk + snapshot (this can take a few minutes)..."
Push-Location $srcDir
$provOut = & $py.Source -m sandbox_mcp.provision 2>&1
Pop-Location
$provOut | ForEach-Object { Write-Host "  $_" }

$vals = @{}
$provOut | ForEach-Object {
    if ($_ -match '^(EXEC_[A-Z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] }
}
if (-not $vals['EXEC_DISK_ID']) {
    Write-Host "[execution] WARNING: provision did not produce a disk image id — check output above"
    exit 0
}

# --- persist for the next provision + update the running Gateway now ---
foreach ($k in 'EXEC_ACR_IMAGE','EXEC_IMAGE_DIGEST','EXEC_DISK_ID','EXEC_SNAPSHOT') {
    if ($vals[$k]) { azd env set $k $vals[$k] 2>$null | Out-Null }
}
if ($worker) { azd env set WORKER_IDENTITY_CLIENT_ID $worker 2>$null | Out-Null }

$appName = az containerapp list -g $rg --query "[?tags.\`"azd-service-name\`"=='openclaw'].name | [0]" -o tsv 2>$null
if (-not $appName) { $appName = az containerapp list -g $rg --query "[0].name" -o tsv 2>$null }
if ($appName) {
    Write-Host "[execution] injecting EXEC_* env into container app '$appName'..."
    $setVars = @("EXECUTION_MODE=sandbox")
    foreach ($k in 'EXEC_ACR_IMAGE','EXEC_IMAGE_DIGEST','EXEC_DISK_ID','EXEC_SNAPSHOT') {
        if ($vals[$k]) { $setVars += "$k=$($vals[$k])" }
    }
    if ($worker) { $setVars += "WORKER_IDENTITY_CLIENT_ID=$worker" }
    az containerapp update -g $rg -n $appName --set-env-vars @setVars -o none 2>$null
    Write-Host "[execution] Gateway updated. Sandbox execution is live."
} else {
    Write-Host "[execution] No container app yet — values persisted to azd env for the next provision."
}
exit 0
