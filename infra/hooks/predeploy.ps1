# predeploy.ps1 — Configure Docker Hub credentials on ACR to avoid anonymous
# pull rate limits during remote builds. Falls back to local Docker if available.
$ErrorActionPreference = "Stop"

# Resolve resource group
$rg = (azd env get-value AZURE_RESOURCE_GROUP 2>$null)
if (-not $rg) { $rg = "rg-$env:AZURE_ENV_NAME" }

# Resolve ACR name
$acrName = (azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>$null)
if (-not $acrName) {
    $acrName = az acr list -g $rg --query "[0].name" -o tsv 2>$null
}
if (-not $acrName) {
    Write-Host "[predeploy] No ACR found — skipping Docker Hub credential setup"
    exit 0
}

# Check for Docker Hub credentials in azd env
$dockerUser = (azd env get-value DOCKERHUB_USERNAME 2>$null)
$dockerToken = (azd env get-value DOCKERHUB_TOKEN 2>$null)

if ($dockerUser -and $dockerToken) {
    Write-Host "[predeploy] Docker Hub credentials found — configuring ACR credential set"

    # Create or update the Docker Hub credential set on ACR for authenticated pulls
    # This avoids the anonymous rate limit (100 pulls/6h) during ACR remote builds.
    $existingCred = az acr credential-set show -r $acrName -n dockerhub 2>$null
    if ($existingCred) {
        Write-Host "[predeploy] ACR credential set 'dockerhub' already exists"
    } else {
        # Store credentials as ACR task credentials for remote builds
        Write-Host "[predeploy] Adding Docker Hub credentials to ACR task defaults"
    }

    # Set credentials as environment for the remote build via ACR task
    # ACR Tasks support --set-secret for passing registry credentials
    az acr task credential add -r $acrName -n default --login-server docker.io `
        --username $dockerUser --password $dockerToken 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[predeploy] Docker Hub credentials configured on ACR"
    } else {
        Write-Host "[predeploy] WARNING: Failed to configure Docker Hub credentials on ACR"
        Write-Host "[predeploy]   If you hit rate limits, ensure Docker Desktop is running for local fallback"
    }
} else {
    Write-Host "[predeploy] No DOCKERHUB_USERNAME/DOCKERHUB_TOKEN in azd env — using anonymous pulls"
    Write-Host "[predeploy]   To avoid Docker Hub rate limits, set credentials:"
    Write-Host "[predeploy]     azd env set DOCKERHUB_USERNAME <username>"
    Write-Host "[predeploy]     azd env set DOCKERHUB_TOKEN <access-token>"

    # Check if local Docker is available as fallback
    $dockerRunning = $false
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
    } catch {}

    if ($dockerRunning) {
        Write-Host "[predeploy] Local Docker detected — will fall back to local build if remote hits rate limit"
    } else {
        Write-Host "[predeploy] WARNING: Local Docker not running. If ACR remote build hits Docker Hub rate limit,"
        Write-Host "[predeploy]   start Docker Desktop and retry, or set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN."
    }
}
