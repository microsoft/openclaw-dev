#!/bin/bash
# predeploy.sh — Configure Docker Hub credentials on ACR to avoid anonymous
# pull rate limits during remote builds. Falls back to local Docker if available.
set -euo pipefail

# Resolve resource group
RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
if [ -z "$RG" ]; then RG="rg-${AZURE_ENV_NAME:-}"; fi

# Resolve ACR name
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
if [ -z "$ACR_NAME" ]; then
    ACR_NAME=$(az acr list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
fi
if [ -z "$ACR_NAME" ]; then
    echo "[predeploy] No ACR found — skipping Docker Hub credential setup"
    exit 0
fi

# Check for Docker Hub credentials in azd env
DOCKER_USER=$(azd env get-value DOCKERHUB_USERNAME 2>/dev/null || echo "")
DOCKER_TOKEN=$(azd env get-value DOCKERHUB_TOKEN 2>/dev/null || echo "")

if [ -n "$DOCKER_USER" ] && [ -n "$DOCKER_TOKEN" ]; then
    echo "[predeploy] Docker Hub credentials found — configuring ACR credential set"

    # Add Docker Hub credentials to ACR task defaults for authenticated pulls
    az acr task credential add -r "$ACR_NAME" -n default --login-server docker.io \
        --username "$DOCKER_USER" --password "$DOCKER_TOKEN" 2>/dev/null && \
        echo "[predeploy] Docker Hub credentials configured on ACR" || {
        echo "[predeploy] WARNING: Failed to configure Docker Hub credentials on ACR"
        echo "[predeploy]   If you hit rate limits, ensure Docker Desktop is running for local fallback"
    }
else
    echo "[predeploy] No DOCKERHUB_USERNAME/DOCKERHUB_TOKEN in azd env — using anonymous pulls"
    echo "[predeploy]   To avoid Docker Hub rate limits, set credentials:"
    echo "[predeploy]     azd env set DOCKERHUB_USERNAME <username>"
    echo "[predeploy]     azd env set DOCKERHUB_TOKEN <access-token>"

    # Check if local Docker is available as fallback
    if docker info >/dev/null 2>&1; then
        echo "[predeploy] Local Docker detected — will fall back to local build if remote hits rate limit"
    else
        echo "[predeploy] WARNING: Local Docker not running. If ACR remote build hits Docker Hub rate limit,"
        echo "[predeploy]   start Docker Desktop and retry, or set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN."
    fi
fi
