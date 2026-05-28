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
  'westcentralus'
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

@description('Region for the Azure OpenAI account. Defaults to `location`. Override (via AZURE_OPENAI_LOCATION) when the chosen `location` does not offer the target model SKU (e.g. ACA in `eastasia` with OpenAI in `eastus2`).')
param openaiLocation string = ''

var effectiveOpenaiLocation = empty(openaiLocation) ? location : openaiLocation

// ---------------------------------------------------------------------------
// 1. AI model — deployed to Azure OpenAI / Microsoft Foundry Models (OpenAI-compatible API)
//    Model name/version are parameterized so any Foundry model exposing the
//    OpenAI API surface can be used here in the future.
// ---------------------------------------------------------------------------
module openai 'resources.bicep' = {
  name: 'openai'
  params: {
    location: effectiveOpenaiLocation
    resourceToken: resourceToken
    environmentName: environmentName
    deployAiModel: true
    aiModelName: 'gpt-5-mini'
    aiModelVersion: '2025-08-07'
    aiModelCapacity: 10
  }
}

// ---------------------------------------------------------------------------
// 2. Host — current implementation: Azure Container Apps with Azure Files.
//    Kept behind a generic `host` module reference so the underlying compute
//    can be swapped (AKS, App Service, etc.) without changing callers.
// ---------------------------------------------------------------------------
module host 'aca.bicep' = {
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
  }
}

// ---------------------------------------------------------------------------
// Outputs (consumed by azd)
// ---------------------------------------------------------------------------
output AZURE_LOCATION string = location
output AZURE_OPENAI_ENDPOINT string = openai.outputs.AZURE_OPENAI_ENDPOINT
output AZURE_OPENAI_NAME string = openai.outputs.AZURE_OPENAI_NAME
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = openai.outputs.AZURE_AI_MODEL_DEPLOYMENT_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = host.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_REGISTRY_NAME string = host.outputs.AZURE_CONTAINER_REGISTRY_NAME
output HOST_FQDN string = host.outputs.HOST_FQDN
output BOT_APP_ID string = host.outputs.BOT_APP_ID
