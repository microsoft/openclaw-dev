// Execution sandbox group for the "orchestrator + sandbox" pattern.
//
// The OpenClaw Gateway stays on ACA (aca.bicep). This module adds the EXECUTION
// layer: a Microsoft.App/SandboxGroups that hosts ephemeral worker sandboxes,
// plus the identities and role assignments that make it keyless:
//   - a user-assigned MI the *workers* use for keyless Azure OpenAI
//   - AcrPull (worker MI) so disk images import from the shared ACR
//   - Cognitive Services User (worker MI) on the OpenAI account
//   - SandboxGroup Data Owner for the *Gateway's* MI so the Gateway (running
//     the sandbox MCP server) can drive the data plane (create/exec/destroy)
//
// Disk images, snapshots and sandboxes are NOT ARM resources — the post-provision
// hook builds them via the adapter (src/sandbox_mcp/provision.py).

param location string
param resourceToken string
param environmentName string

@description('Azure OpenAI resource ID (for the worker MI role assignment scope)')
param openaiResourceId string

@description('Name of the shared ACR the execution image is pushed to')
param acrName string

@description('Principal ID of the Gateway container app MI — granted SandboxGroup Data Owner so the Gateway can drive the data plane')
param gatewayPrincipalId string = ''

// Container Apps SandboxGroup Data Owner (well-known role definition GUID).
var sandboxDataOwnerRoleId = 'c24cf47c-5077-412d-a19c-45202126392c'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// --- Worker managed identity (keyless Azure OpenAI for sandbox workers) ---
resource workerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-exec-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerIdentity.id, acr.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: workerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalType: 'ServicePrincipal'
  }
}

// --- Sandbox group (preview / Early Access) with the worker MI attached ---
#disable-next-line BCP081
resource sandboxGroup 'Microsoft.App/SandboxGroups@2026-02-01-preview' = {
  name: 'sbg-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${workerIdentity.id}': {}
    }
  }
  properties: {}
}

// --- Worker MI: Cognitive Services User on the OpenAI account (keyless model) ---
resource openaiResource 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(openaiResourceId, '/'))
}

resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerIdentity.id, openaiResource.id, 'a97b65f3-24c7-4388-baec-2e87135dc908')
  scope: openaiResource
  properties: {
    principalId: workerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
    )
    principalType: 'ServicePrincipal'
  }
}

// --- Gateway MI: SandboxGroup Data Owner on the group (drives the data plane) ---
resource gatewayDataOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(gatewayPrincipalId)) {
  name: guid(subscription().id, gatewayPrincipalId, sandboxGroup.id, sandboxDataOwnerRoleId)
  scope: sandboxGroup
  properties: {
    principalId: gatewayPrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      sandboxDataOwnerRoleId
    )
    principalType: 'ServicePrincipal'
  }
}

output AZURE_SANDBOX_GROUP_NAME string = sandboxGroup.name
output WORKER_IDENTITY_CLIENT_ID string = workerIdentity.properties.clientId
output WORKER_IDENTITY_PRINCIPAL_ID string = workerIdentity.properties.principalId
