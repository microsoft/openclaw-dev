// Azure OpenAI resource — adapted from https://aka.ms/openai/start
// Deploys a Cognitive Services (OpenAI) account with a GPT-5-mini model

@description('Primary location for all resources')
param location string = resourceGroup().location

@description('Unique token for resource naming')
param resourceToken string

@description('Environment name for tagging')
param environmentName string

@description('The SKU for the Azure OpenAI resource')
@allowed(['S0'])
param sku string = 'S0'

@description('Deploy GPT model automatically')
param deployGptModel bool = true

@description('GPT model to deploy')
param gptModelName string = 'gpt-5-mini'

@description('GPT model version')
param gptModelVersion string = '2025-08-07'

@description('GPT deployment capacity (tokens-per-minute in thousands)')
param gptCapacity int = 10

@description('Principal ID of the deploying user. If provided, assigns Cognitive Services User role.')
param principalId string = ''

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
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    // Disable API key auth — managed identity only (keyless)
    disableLocalAuth: true
    // Assign Cognitive Services User role to the deploying user for keyless (EntraID) access
    roleAssignments: !empty(principalId) ? [
      {
        principalId: principalId
        roleDefinitionIdOrName: 'Cognitive Services User'
        principalType: 'User'
      }
    ] : []
    deployments: deployGptModel ? [
      {
        name: gptModelName
        model: {
          format: 'OpenAI'
          name: gptModelName
          version: gptModelVersion
        }
        sku: {
          name: 'GlobalStandard'
          capacity: gptCapacity
        }
      }
    ] : []
  }
}

// Outputs
output AZURE_OPENAI_ENDPOINT string = openai.outputs.endpoint
output AZURE_OPENAI_NAME string = openai.outputs.name
output AZURE_OPENAI_RESOURCE_ID string = openai.outputs.resourceId
output AZURE_OPENAI_GPT_DEPLOYMENT_NAME string = deployGptModel ? gptModelName : ''
