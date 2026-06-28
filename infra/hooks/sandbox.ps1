# sandbox.ps1 — ACA Sandboxes host bring-up (USE_SANDBOX=true).
#
# Runs after `azd provision` (invoked from postprovision.ps1). Bicep has already
# created the sandbox group (Microsoft.App/SandboxGroups), a user-assigned
# managed identity attached to it, ACR, and the AcrPull + Cognitive Services
# User role assignments. This script drives the ADC *data plane* via the `aca`
# CLI to:
#   1. build the OpenClaw image into ACR (az acr build, passwordless)
#   2. import it as a private sandbox disk image
#   3. boot a sandbox from that disk image with the keyless-OpenAI env contract
#   4. start the OpenClaw gateway inside the sandbox and expose its port
#
# Idempotent-ish and best-effort: the azure.yaml postprovision hook is
# continueOnError, so a partial failure here never bricks `azd provision`.
$ErrorActionPreference = "Stop"

function Get-AzdValue([string]$Key) {
    $v = (azd env get-value $Key 2>$null)
    if (-not $v -or $v -match 'ERROR|not found') { return "" }
    return $v.Trim()
}

# --- Ensure az CLI is authenticated (azd hooks use a repo-local config dir) ---
$authOk = $false
try { & az account show -o none 2>$null; if ($LASTEXITCODE -eq 0) { $authOk = $true } } catch {}
if (-not $authOk -and $env:AZURE_CONFIG_DIR) {
    Write-Host "[sandbox] az not authenticated in AZURE_CONFIG_DIR — falling back to default config dir"
    Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
    try { & az account show -o none 2>$null; if ($LASTEXITCODE -eq 0) { $authOk = $true } } catch {}
}
if (-not $authOk) {
    Write-Host "[sandbox] WARNING: az not authenticated — skipping sandbox bring-up"
    exit 0
}

# --- Resolve configuration from the azd environment ---
$sub        = Get-AzdValue AZURE_SUBSCRIPTION_ID
$rg         = Get-AzdValue AZURE_RESOURCE_GROUP
if (-not $rg) { $rg = "rg-$env:AZURE_ENV_NAME" }
$region     = Get-AzdValue AZURE_LOCATION
$group      = Get-AzdValue AZURE_SANDBOX_GROUP_NAME
$acrName    = Get-AzdValue AZURE_CONTAINER_REGISTRY_NAME
$acrServer  = Get-AzdValue AZURE_CONTAINER_REGISTRY_ENDPOINT
$openaiBase = Get-AzdValue AZURE_OPENAI_ENDPOINT
$deployment = Get-AzdValue AZURE_AI_MODEL_DEPLOYMENT_NAME
$miClientId = Get-AzdValue AZURE_SANDBOX_IDENTITY_CLIENT_ID
$publicMode = (Get-AzdValue SANDBOX_PUBLIC).ToLower() -eq 'true'
$allowDomain = (Get-AzdValue SANDBOX_ALLOW_DOMAIN).ToLower() -eq 'true'
# Transient per-invocation flags (process env, not azd env): `devclaw clone`
# sets both to reuse the latest disk image and boot an extra, additive instance.
$reuseDisk = ($env:SANDBOX_REUSE_DISK) -and ($env:SANDBOX_REUSE_DISK.ToString().ToLower() -eq 'true')
$cloneMode = ($env:SANDBOX_CLONE) -and ($env:SANDBOX_CLONE.ToString().ToLower() -eq 'true')
$port       = Get-AzdValue SANDBOX_PORT
if (-not $port) { $port = "18789" }

if (-not $group) {
    Write-Host "[sandbox] No AZURE_SANDBOX_GROUP_NAME in env — was provisioning run with USE_SANDBOX=true? Skipping."
    exit 0
}
if (-not $acrName) { $acrName = az acr list -g $rg --query "[0].name" -o tsv 2>$null }
if (-not $acrServer -and $acrName) { $acrServer = az acr show -n $acrName --query loginServer -o tsv 2>$null }

Write-Host "[sandbox] Group=$group  RG=$rg  Region=$region  ACR=$acrServer"

# --- Ensure the `aca` CLI is installed ---
$acaOk = $false
try { & aca --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $acaOk = $true } } catch {}
if (-not $acaOk) {
    Write-Host "[sandbox] Installing the aca CLI (https://aka.ms/aca-cli-install-ps)..."
    try { Invoke-RestMethod https://aka.ms/aca-cli-install-ps | Invoke-Expression } catch {
        Write-Host "[sandbox] WARNING: automatic aca CLI install failed: $($_.Exception.Message)"
    }
    # The installer may extend PATH only for new shells; probe common install dirs.
    if (-not (Get-Command aca -ErrorAction SilentlyContinue)) {
        foreach ($p in @("$env:LOCALAPPDATA\Programs\aca", "$env:USERPROFILE\.aca\bin", "$env:LOCALAPPDATA\aca\bin")) {
            if (Test-Path (Join-Path $p 'aca.exe')) { $env:PATH = "$p;$env:PATH"; break }
        }
    }
    try { & aca --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $acaOk = $true } } catch {}
}
if (-not $acaOk) {
    Write-Host "[sandbox] WARNING: aca CLI not available. Install it (https://aka.ms/aca-cli-install) and re-run 'devclaw up'."
    Write-Host "[sandbox] The sandbox group '$group' is already provisioned; only the data-plane bring-up was skipped."
    exit 0
}

# --- Point the aca CLI at this group/subscription/region ---
if ($sub) { aca config set -s $sub -g $rg --sandbox-group $group --region $region 2>$null | Out-Null }
aca config sandbox set --group $group --region $region 2>$null | Out-Null

# --- Grant the deploying principal data-plane access (idempotent) ---
$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if ($principalId) {
    Write-Host "[sandbox] Ensuring 'Container Apps SandboxGroup Data Owner' for the deployer..."
    aca sandboxgroup role create --group $group --role "Container Apps SandboxGroup Data Owner" --principal-id $principalId 2>$null | Out-Null
}
aca doctor 2>$null | Out-Null

# --- Resolve the disk image: reuse the latest (clone) or build a fresh one ---
$diskId = ""
if ($reuseDisk) {
    Write-Host "[sandbox] Reusing the latest existing disk image (no rebuild)..."
    try {
        $disks = aca sandboxgroup disk list --group $group -o json 2>$null | ConvertFrom-Json
        if ($disks) {
            $latest = $disks | Sort-Object { $_.status.createdAt } -Descending | Select-Object -First 1
            $diskId = $latest.id
        }
    } catch {}
    if (-not $diskId) {
        Write-Host "[sandbox] No existing disk image in the group. Run 'devclaw up' first to build one."
        exit 0
    }
    Write-Host "[sandbox] Reusing disk image id: $diskId"
} else {
    # Build the OpenClaw image into ACR (passwordless remote build).
    $tag = "sandbox-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $image = "openclaw:$tag"
    $srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) "..\src" | Resolve-Path
    Write-Host "[sandbox] Building $image into $acrName via 'az acr build'..."
    az acr build --registry $acrName --image $image --file (Join-Path $srcDir "Dockerfile") $srcDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[sandbox] WARNING: image build failed. If this is a Docker Hub rate limit, set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN and re-run."
        exit 0
    }
    $imageRef = "$acrServer/$image"
    # Import the ACR image as a private disk image. Managed-identity ACR pull
    # (--identity) returns 401 during the preview (needs a feature flag), so use
    # a short-lived AAD ACR token instead — still passwordless (no admin creds).
    # The username is the well-known ACR token GUID.
    $diskName = "openclaw-$tag"
    Write-Host "[sandbox] Importing disk image '$diskName' from $imageRef..."
    $acrToken = az acr login -n $acrName --expose-token --query accessToken -o tsv 2>$null
    if (-not $acrToken) {
        Write-Host "[sandbox] WARNING: could not obtain an ACR token ('az acr login --expose-token'). Skipping."
        exit 0
    }
    $diskJson = aca sandboxgroup disk create --group $group --image $imageRef --name $diskName `
        --username "00000000-0000-0000-0000-000000000000" --token $acrToken -o json 2>$null
    if ($diskJson) { try { $diskId = ($diskJson | ConvertFrom-Json).id } catch {} }
    if (-not $diskId) {
        Write-Host "[sandbox] WARNING: disk image import failed. Inspect 'aca sandboxgroup disk create --help'."
        exit 0
    }
    Write-Host "[sandbox] Disk image id: $diskId"
}

# --- Boot the sandbox with the keyless-OpenAI env contract ---
# The disk image carries the container ENTRYPOINT (/opt/entrypoint.sh), which
# the sandbox runs automatically at boot using these --env values — it starts
# the gateway-proxy on 0.0.0.0:$port and the gateway on :18788. Do NOT exec the
# entrypoint manually afterward (it double-starts and trips the gateway lock).
$gatewayToken = (-join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }))
$openaiV1 = if ($openaiBase.EndsWith('/')) { "${openaiBase}openai/v1/" } else { "$openaiBase/openai/v1/" }
$sbxLabel = if ($cloneMode) { 'openclaw-clone' } else { 'openclaw' }
Write-Host "[sandbox] Booting sandbox '$sbxLabel' from disk image..."
$sbxOut = aca sandbox create --group $group --disk-id $diskId `
    --cpu 1000m --memory 2048Mi `
    --label name=$sbxLabel `
    --env "OPENAI_BASE_URL=$openaiV1" `
    --env "OPENAI_MODEL_DEPLOYMENT=$deployment" `
    --env "AZURE_OPENAI_AUTH=managed-identity" `
    --env "AZURE_CLIENT_ID=$miClientId" `
    --env "OPENCLAW_GATEWAY_TOKEN=$gatewayToken" `
    -o json 2>&1
# `sandbox create` prints human-readable status even with -o json, so parse the
# id from JSON when possible and fall back to the first UUID in the output.
$sbxId = ""
try { $sbxId = ($sbxOut | ConvertFrom-Json).id } catch {}
if (-not $sbxId) {
    $m = [regex]::Match((($sbxOut | Out-String)), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { $sbxId = $m.Value }
}
if (-not $sbxId) {
    Write-Host "[sandbox] WARNING: sandbox create failed. Check 'aca doctor' and the Data Owner role assignment."
    exit 0
}
Write-Host "[sandbox] Sandbox id: $sbxId"

# --- Wait for the auto-started gateway to come up, then expose the port ---
Write-Host "[sandbox] Waiting for the gateway to start inside the sandbox..."
Start-Sleep -Seconds 20

# --- Expose the gateway port ---
# SANDBOX_PUBLIC=true → anonymous URL. Otherwise Entra-gate the port. The CLI
# only offers --email, which is brittle: guest/B2B sign-ins present a #EXT# UPN
# rather than the `mail` claim, so an exact email match can fail. Instead we
# POST a richer allow-list to the ADC data plane (`az rest`): the deployer's
# object id (the reliable `oid` claim) + email, plus the org email-domain
# suffix when SANDBOX_ALLOW_DOMAIN=true (lets any corporate login in).
$url = ""
function Add-AnonymousPort {
    $pj = aca sandbox port add --id $sbxId --port $port --anonymous -o json 2>$null
    if ($pj) { try { $p = $pj | ConvertFrom-Json; if ($p.url) { return $p.url } elseif ($p[0].url) { return $p[0].url } } catch {} }
    return ""
}
if ($publicMode) {
    Write-Host "[sandbox] Exposing port $port (anonymous — anyone with the URL can reach it; SANDBOX_PUBLIC=true)..."
    $url = Add-AnonymousPort
} else {
    $oid  = az ad signed-in-user show --query id -o tsv 2>$null
    $mail = az ad signed-in-user show --query mail -o tsv 2>$null
    $entra = [ordered]@{ enabled = $true }
    if ($oid) { $entra.objectIds = @($oid) }
    $domain = ""
    if ($mail -and $mail -match '^[^@\s]+@([^@\s]+\.[^@\s]+)$') {
        $domain = $Matches[1]
        $entra.emails = @($mail)
        if ($allowDomain) { $entra.emailSuffixes = @('@' + $domain) }
    }
    if (-not ($entra.Contains('objectIds') -or $entra.Contains('emails'))) {
        Write-Host "[sandbox] Could not resolve the deployer identity — exposing port $port anonymously."
        $url = Add-AnonymousPort
    } else {
        $gateDesc = if ($allowDomain -and $domain) { "any @$domain login + you" } else { "the deployer" }
        Write-Host "[sandbox] Exposing port $port (Entra-gated to $gateDesc; set SANDBOX_PUBLIC=true for an anonymous URL)..."
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sbxport-" + [Guid]::NewGuid().ToString('N') + ".json")
        (@{ port = [int]$port; auth = @{ entraId = $entra } } | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $tmp -Encoding ascii -NoNewline
        $uri = "https://management.$region.azuredevcompute.io/subscriptions/$sub/resourceGroups/$rg/sandboxGroups/$group/sandboxes/$sbxId/ports/add?api-version=2026-02-01-preview"
        $respRaw = az rest --method post --url $uri --resource "https://dynamicsessions.io" --headers "Content-Type=application/json" --body "@$tmp" 2>$null
        Remove-Item $tmp -ErrorAction SilentlyContinue
        if ($respRaw) { try { $r = $respRaw | ConvertFrom-Json; $url = ($r.ports | Select-Object -First 1).url } catch {} }
        if (-not $url) {
            Write-Host "[sandbox] WARNING: Entra-gated port add failed — falling back to anonymous."
            $url = Add-AnonymousPort
        }
    }
}

# --- Clone mode: additive extra instance — print it, don't touch primary env ---
if ($cloneMode) {
    Write-Host ""
    Write-Host "[sandbox] OpenClaw CLONE is up (reused the existing image — no rebuild)."
    if ($url) {
        Write-Host "[sandbox]   URL:   $url#token=$gatewayToken"
        if (-not $publicMode) { Write-Host "[sandbox]   Access: Entra-gated — sign in with the deploying account." }
    } else {
        Write-Host "[sandbox]   Port exposed, but no URL was returned. Run: aca sandbox port list --id $sbxId"
    }
    Write-Host "[sandbox]   Sandbox: $sbxId"
    Write-Host "[sandbox]   Delete:  aca sandbox delete --id $sbxId --yes"
    Write-Host ""
    exit 0
}

# --- Persist outputs to the azd environment ---
azd env set AZURE_SANDBOX_ID $sbxId 2>$null | Out-Null
azd env set OPENCLAW_GATEWAY_TOKEN $gatewayToken 2>$null | Out-Null
if ($url) {
    azd env set SANDBOX_URL $url 2>$null | Out-Null
    $hostOnly = ([Uri]$url).Host
    if ($hostOnly) { azd env set HOST_FQDN $hostOnly 2>$null | Out-Null }
}

Write-Host ""
Write-Host "[sandbox] OpenClaw sandbox is up."
if ($url) {
    Write-Host "[sandbox]   URL:   $url#token=$gatewayToken"
    if (-not $publicMode) { Write-Host "[sandbox]   Access: Entra-gated — sign in with the deploying account." }
} else {
    Write-Host "[sandbox]   Port exposed, but no URL was returned. Run: aca sandbox port list --id $sbxId"
}
Write-Host "[sandbox]   Shell: aca sandbox shell --id $sbxId"
Write-Host ""
exit 0
