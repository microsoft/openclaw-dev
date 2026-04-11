// OpenClaw on Azure — azd orchestration template
// Provisions Azure OpenAI (GPT-5-mini, v1 API) + Azure Container Apps with persistent storage
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
// 1. Azure OpenAI — GPT-5-mini via the v1 API (from aka.ms/openai/start)
// ---------------------------------------------------------------------------
module openai 'resources.bicep' = {
  name: 'openai'
  params: {
    location: location
    resourceToken: resourceToken
    environmentName: environmentName
    deployGptModel: true
    gptModelName: 'gpt-5-mini'
    gptModelVersion: '2025-08-07'
    gptCapacity: 10
  }
}

// ---------------------------------------------------------------------------
// 2. Azure Container Apps — hosts OpenClaw with Azure Files state persistence
// ---------------------------------------------------------------------------
module aca 'aca.bicep' = {
  name: 'aca'
  params: {
    location: location
    resourceToken: resourceToken
    environmentName: environmentName
    openaiEndpoint: openai.outputs.AZURE_OPENAI_ENDPOINT
    openaiDeploymentName: openai.outputs.AZURE_OPENAI_GPT_DEPLOYMENT_NAME
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
output AZURE_OPENAI_GPT_DEPLOYMENT_NAME string = openai.outputs.AZURE_OPENAI_GPT_DEPLOYMENT_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = aca.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_REGISTRY_NAME string = aca.outputs.AZURE_CONTAINER_REGISTRY_NAME
output CONTAINER_APP_FQDN string = aca.outputs.CONTAINER_APP_FQDN
output BOT_APP_ID string = aca.outputs.BOT_APP_ID
