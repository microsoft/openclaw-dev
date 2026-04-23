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

// ---------------------------------------------------------------------------
// 1. AI model — deployed to Azure OpenAI / Microsoft Foundry Models (OpenAI-compatible API)
//    Model name/version are parameterized so any Foundry model exposing the
//    OpenAI API surface can be used here in the future.
// ---------------------------------------------------------------------------
module openai 'resources.bicep' = {
  name: 'openai'
  params: {
    location: location
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
