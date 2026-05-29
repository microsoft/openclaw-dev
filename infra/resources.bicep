// Azure OpenAI / Microsoft Foundry Models resource — adapted from https://aka.ms/openai/start
// Deploys a Cognitive Services (OpenAI) account with a single model deployment.
// Model name/version are parameterized; today this targets Azure OpenAI models,
// with scope to add Claude and other Foundry Models in the near future.

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

@description('AI model to deploy (Azure OpenAI in Foundry Models; default gpt-5-mini)')
param aiModelName string = 'gpt-5-mini'

@description('AI model version')
param aiModelVersion string = '2025-08-07'

@description('AI model deployment capacity (tokens-per-minute in thousands)')
param aiModelCapacity int = 10

// Deploy the Azure OpenAI account via AVM (account only — no model deployment).
// We create the model deployment as a native resource below so we can attach a
// custom RAI (content-filter) policy that disables Prompt Shield jailbreak
// blocking. Without this, OpenClaw's "Sender (untrusted metadata)" envelope
// pattern-matches as injection on the Responses API and gets a 0-token canned
// refusal returned before the model runs.
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
    disableLocalAuth: true
    roleAssignments: []
    deployments: []
  }
}

// Reference the AVM-created account so we can attach a RAI policy and a
// deployment to it as native resources.
resource openaiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: 'openai-${resourceToken}'
  dependsOn: [openai]
}

// Custom RAI (content filter) policy — same defaults as Microsoft.DefaultV2
// EXCEPT Prompt Shield jailbreak detection is non-blocking. This is required
// for OpenClaw's anti-injection sender envelope to pass through on the
// Responses API; standard hate/violence/sexual/self-harm filters stay enabled.
resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: openaiAccount
  name: 'openclaw-relaxed-jailbreak'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    contentFilters: [
      // Input — relax jailbreak detection from blocking to annotate-only
      {
        name: 'Jailbreak'
        blocking: false
        enabled: true
        source: 'Prompt'
      }
      // Input — relax indirect attack (XPIA) detection. OpenClaw's
      // "Sender (untrusted metadata)" envelope pattern-matches as XPIA.
      {
        name: 'Indirect Attack'
        blocking: false
        enabled: true
        source: 'Prompt'
      }
      // Inputs — keep default blocking thresholds
      { name: 'Hate', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Sexual', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Violence', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Selfharm', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      // Outputs — keep default blocking thresholds
      { name: 'Hate', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Sexual', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Violence', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Selfharm', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
    ]
  }
}

// Model deployment with the relaxed RAI policy attached.
resource aiModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployAiModel) {
  parent: openaiAccount
  name: aiModelName
  sku: {
    name: 'GlobalStandard'
    capacity: aiModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: aiModelName
      version: aiModelVersion
    }
    raiPolicyName: raiPolicy.name
  }
}

// Outputs
output AZURE_OPENAI_ENDPOINT string = openai.outputs.endpoint
output AZURE_OPENAI_NAME string = openai.outputs.name
output AZURE_OPENAI_RESOURCE_ID string = openai.outputs.resourceId
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = deployAiModel ? aiModelName : ''
