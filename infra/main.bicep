// OpenClaw on Azure — azd orchestration template
// Provisions a Microsoft Foundry Models / Azure OpenAI model (OpenAI-compatible API)
// plus a container host (currently Azure Container Apps; swappable in the future).
targetScope = 'resourceGroup'

@description('Environment name for tagging')
@minLength(1)
@maxLength(64)
param environmentName string

@description('Primary location for all resources')
@allowed([
  'australiaeast'
  'eastasia'
  'eastus'
  'eastus2'
  'japaneast'
  'koreacentral'
  'southindia'
  'swedencentral'
  'switzerlandnorth'
  'uksouth'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

@description('Unique token for resource naming')
param resourceToken string = toLower(uniqueString(subscription().id, environmentName, location))

@description('Bot App Registration ID (created by preprovision hook)')
param botAppId string = ''

@description('Bot App Registration Secret (created by preprovision hook)')
@secure()
param botAppSecret string = ''

@description('Bot Tenant ID')
param botTenantId string = subscription().tenantId

@description('Easy Auth App Registration ID (created by preprovision hook)')
param easyAuthAppId string = ''

@description('Container image to deploy. azd populates from SERVICE_OPENCLAW_IMAGE_NAME after first deploy; empty on first provision (placeholder used).')
param containerImage string = ''

@description('Opt into ACA Express mode (preview). Set USE_EXPRESS_ENV=true in your azd env. Only enable in regions that support Express — e.g. East Asia, West Central US.')
param useExpressEnv string = 'false'

var expressEnabled = toLower(useExpressEnv) == 'true'

@description('EXPERIMENTAL: run the *entire* Gateway inside an ACA Sandbox instead of a Container App (host replacement). Most deployments should leave this false and instead use EXECUTION_MODE=sandbox, which keeps the Gateway on ACA and offloads only untrusted execution to sandboxes.')
param useSandbox string = 'false'

var sandboxEnabled = toLower(useSandbox) == 'true'

@description('Execution mode: inproc (default — today\'s single container) or sandbox (keep the Gateway on ACA and offload untrusted tool execution to ephemeral ACA Sandboxes via the sandbox MCP server). Set EXECUTION_MODE in your azd env.')
param executionMode string = 'inproc'

var executionSandbox = toLower(executionMode) == 'sandbox' && !sandboxEnabled
var sandboxGroupName = 'sbg-${resourceToken}'

@description('Worker MI client-id + execution image/disk/snapshot ids. Empty on first provision; the post-provision hook fills them and re-injects on the next provision.')
param workerIdentityClientId string = ''
param execAcrImage string = ''
param execImageDigest string = ''
param execDiskId string = ''
param execSnapshot string = ''

@description('Set SKIP_STORAGE=true in your azd env to skip the storage account + Azure Files volume mount. Use on subscriptions where Azure Policy blocks `allowSharedKeyAccess: true` on storage accounts (ACA file mounts require shared keys today). Trade-off: gateway token + sessions do not persist across replica restarts.')
param skipStorage string = 'false'

var storageSkipped = toLower(skipStorage) == 'true'

@description('Region for the Azure OpenAI account. Defaults to `location`. Override (via AZURE_OPENAI_LOCATION) when the chosen `location` does not offer the target model SKU (e.g. ACA in `eastasia` with OpenAI in `eastus2`).')
param openaiLocation string = ''

var effectiveOpenaiLocation = empty(openaiLocation) ? location : openaiLocation

// ---------------------------------------------------------------------------
// 1. AI model — deployed to Azure OpenAI / Microsoft Foundry Models (OpenAI-compatible API)
//    Model name/version are parameterized; today this targets Azure OpenAI models,
//    with scope to add Claude and other Foundry Models in the near future.
// ---------------------------------------------------------------------------
module openai 'resources.bicep' = {
  name: 'openai'
  params: {
    location: effectiveOpenaiLocation
    resourceToken: resourceToken
    environmentName: environmentName
    deployAiModel: true
    aiModelName: 'gpt-5.4-mini'
    aiModelVersion: '2026-03-17'
    aiModelCapacity: 50
  }
}

// ---------------------------------------------------------------------------
// 2. Host — one of two mutually exclusive compute backends:
//    a) Azure Container Apps with Azure Files (default), or
//    b) ACA Sandboxes (USE_SANDBOX=true) — a Microsoft.App/SandboxGroups
//       resource + managed identity; the sandbox itself is booted post-provision
//       by the `aca` CLI (see infra/hooks/sandbox.(ps1|sh)).
//    Kept behind a generic `host` reference so the underlying compute can be
//    swapped (AKS, App Service, etc.) without changing callers.
// ---------------------------------------------------------------------------
module host 'aca.bicep' = if (!sandboxEnabled) {
  name: 'host'
  params: {
    location: location
    resourceToken: resourceToken
    environmentName: environmentName
    openaiEndpoint: openai.outputs.AZURE_OPENAI_ENDPOINT
    openaiDeploymentName: openai.outputs.AZURE_AI_MODEL_DEPLOYMENT_NAME
    openaiResourceId: openai.outputs.AZURE_OPENAI_RESOURCE_ID
    botAppId: botAppId
    botAppSecret: botAppSecret
    botTenantId: botTenantId
    easyAuthAppId: easyAuthAppId
    containerImage: containerImage
    useExpressEnv: expressEnabled
    skipStorage: storageSkipped
    executionMode: executionMode
    sandboxGroupName: sandboxGroupName
    workerIdentityClientId: workerIdentityClientId
    execAcrImage: execAcrImage
    execImageDigest: execImageDigest
    execDiskId: execDiskId
    execSnapshot: execSnapshot
  }
}

module sandboxHost 'sandbox.bicep' = if (sandboxEnabled) {
  name: 'sandbox-host'
  params: {
    location: location
    resourceToken: resourceToken
    environmentName: environmentName
    openaiResourceId: openai.outputs.AZURE_OPENAI_RESOURCE_ID
  }
}

// ---------------------------------------------------------------------------
// 3. Execution layer (EXECUTION_MODE=sandbox): the Gateway stays on ACA and
//    offloads untrusted tool execution to ephemeral ACA Sandboxes. Bicep
//    provisions the group + worker MI + role assignments (incl. SandboxGroup
//    Data Owner for the Gateway MI); the post-provision hook builds the exec
//    image, the hash-gated disk image, and the warm snapshot.
// ---------------------------------------------------------------------------
module execution 'execution.bicep' = if (executionSandbox) {
  name: 'execution'
  params: {
    location: location
    resourceToken: resourceToken
    environmentName: environmentName
    openaiResourceId: openai.outputs.AZURE_OPENAI_RESOURCE_ID
    acrName: host!.outputs.AZURE_CONTAINER_REGISTRY_NAME
    gatewayPrincipalId: host!.outputs.HOST_PRINCIPAL_ID
  }
}

// ---------------------------------------------------------------------------
// Outputs (consumed by azd). Host-specific outputs degrade to empty strings
// for whichever backend is not deployed.
// ---------------------------------------------------------------------------
output AZURE_LOCATION string = location
output USE_SANDBOX string = sandboxEnabled ? 'true' : 'false'
output EXECUTION_MODE string = executionSandbox ? 'sandbox' : 'inproc'
output AZURE_OPENAI_ENDPOINT string = openai.outputs.AZURE_OPENAI_ENDPOINT
output AZURE_OPENAI_NAME string = openai.outputs.AZURE_OPENAI_NAME
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = openai.outputs.AZURE_AI_MODEL_DEPLOYMENT_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = sandboxEnabled ? sandboxHost!.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT : host!.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_REGISTRY_NAME string = sandboxEnabled ? sandboxHost!.outputs.AZURE_CONTAINER_REGISTRY_NAME : host!.outputs.AZURE_CONTAINER_REGISTRY_NAME
output HOST_FQDN string = sandboxEnabled ? '' : host!.outputs.HOST_FQDN
output BOT_APP_ID string = sandboxEnabled ? '' : host!.outputs.BOT_APP_ID
output AZURE_SANDBOX_GROUP_NAME string = sandboxEnabled ? sandboxHost!.outputs.AZURE_SANDBOX_GROUP_NAME : (executionSandbox ? execution!.outputs.AZURE_SANDBOX_GROUP_NAME : '')
output AZURE_SANDBOX_IDENTITY_CLIENT_ID string = sandboxEnabled ? sandboxHost!.outputs.AZURE_SANDBOX_IDENTITY_CLIENT_ID : ''
output WORKER_IDENTITY_CLIENT_ID string = executionSandbox ? execution!.outputs.WORKER_IDENTITY_CLIENT_ID : ''
