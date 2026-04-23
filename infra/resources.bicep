// Azure OpenAI / Microsoft Foundry Models resource — adapted from https://aka.ms/openai/start
// Deploys a Cognitive Services (OpenAI) account with a single model deployment.
// Model name/version are parameterized so any Foundry model that exposes the
// OpenAI-compatible API can be used.

@description('Primary location for all resources')
param location string = resourceGroup().location

@description('Unique token for resource naming')
param resourceToken string

@description('Environment name for tagging')
param environmentName string

@description('The SKU for the Azure OpenAI resource')
@allowed(['S0'])
param sku string = 'S0'

@description('Deploy the AI model automatically')
param deployAiModel bool = true

@description('AI model to deploy (any OpenAI-compatible Foundry model)')
param aiModelName string = 'gpt-5-mini'

@description('AI model version')
param aiModelVersion string = '2025-08-07'

@description('AI model deployment capacity (tokens-per-minute in thousands)')
param aiModelCapacity int = 10

// Deploy the Azure OpenAI resource via AVM
module openai 'br/public:avm/res/cognitive-services/account:0.13.2' = {
  name: 'openai-account'
  params: {
    name: 'openai-${resourceToken}'
    location: location
    tags: {
      'azd-env-name': environmentName
    }
    kind: 'OpenAI'
    sku: sku
    customSubDomainName: 'openai-${resourceToken}'
    // Public network access allowed (no VNet) — security is via managed identity + disableLocalAuth
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    // Disable API key auth — managed identity only (keyless)
    // This is the primary security control: no API keys exist, only Entra ID tokens work
    disableLocalAuth: true
    // No deploying-user role assignment needed — only the Container App's
    // managed identity gets Cognitive Services User (assigned in aca.bicep)
    roleAssignments: []
    deployments: deployAiModel ? [
      {
        name: aiModelName
        model: {
          format: 'OpenAI'
          name: aiModelName
          version: aiModelVersion
        }
        sku: {
          name: 'GlobalStandard'
          capacity: aiModelCapacity
        }
      }
    ] : []
  }
}

// Outputs
output AZURE_OPENAI_ENDPOINT string = openai.outputs.endpoint
output AZURE_OPENAI_NAME string = openai.outputs.name
output AZURE_OPENAI_RESOURCE_ID string = openai.outputs.resourceId
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = deployAiModel ? aiModelName : ''
