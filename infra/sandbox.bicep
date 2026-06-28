// Azure Container Apps Sandboxes host for OpenClaw — alternate to aca.bicep.
// Opt in with `azd env set USE_SANDBOX true` (mutually exclusive with the
// Container Apps host). Provisions only the ARM control-plane pieces:
//   - ACR (admin disabled; pulled via the sandbox group's managed identity)
//   - a user-assigned Managed Identity attached to the sandbox group
//   - the Microsoft.App/SandboxGroups resource (preview / Early Access)
//   - role assignments so the group MI can pull the OpenClaw image from ACR
//     (AcrPull) and call Azure OpenAI keyless (Cognitive Services User)
//
// The data-plane resources — disk images, sandboxes, exposed ports — are NOT
// ARM resources. They live behind the ADC data plane and are created after
// provisioning by the `aca` CLI in infra/hooks/sandbox.(ps1|sh).

param location string
param resourceToken string
param environmentName string

@description('Azure OpenAI resource ID (for role assignment scoping)')
param openaiResourceId string

// ---------------------------------------------------------------------------
// Azure Container Registry — admin disabled (common Azure Policy). The
// OpenClaw image is built into this registry by the sandbox hook (az acr
// build) and then imported as a sandbox disk image. The sandbox group's
// managed identity is granted AcrPull below so the import is passwordless.
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${resourceToken}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
  tags: { 'azd-env-name': environmentName }
}

// ---------------------------------------------------------------------------
// User-assigned Managed Identity — attached to the sandbox group so sandboxes
// get token-broker access to Azure (keyless Azure OpenAI) and the platform can
// pull the disk-image source from ACR.
// ---------------------------------------------------------------------------
resource sandboxIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-sandbox-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
}

// AcrPull on the registry for the sandbox group's MI — needed so the disk
// image can be built from the private OpenClaw image without admin creds.
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, sandboxIdentity.id, acr.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: sandboxIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Sandbox group (preview / Early Access).
//
// NOTE: `Microsoft.App/SandboxGroups` is an Early Access resource type and is
// not yet in the public Bicep/ARM type catalog, so the line below emits a
// BCP081 "type not available" warning (suppressed). The api-version literal is
// the one registered for this provider (verified via `az provider show
// --namespace Microsoft.App`); it cannot be a Bicep parameter because the
// api-version is part of the type. If your subscription registers
// SandboxGroups under a different api-version, update the literal below.
// Requires the Early Access feature enabled on the subscription.
// ---------------------------------------------------------------------------
#disable-next-line BCP081
resource sandboxGroup 'Microsoft.App/SandboxGroups@2026-02-01-preview' = {
  name: 'sbg-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sandboxIdentity.id}': {}
    }
  }
  properties: {}
}

// ---------------------------------------------------------------------------
// RBAC — Cognitive Services User for the sandbox group MI on the OpenAI
// account, so sandboxes call the model keyless (managed identity).
// ---------------------------------------------------------------------------
resource openaiResource 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(openaiResourceId, '/'))
}

resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, sandboxIdentity.id, openaiResource.id, 'a97b65f3-24c7-4388-baec-2e87135dc908')
  scope: openaiResource
  properties: {
    principalId: sandboxIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
    )
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs — consumed by azd env and the sandbox hook.
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
output AZURE_SANDBOX_GROUP_NAME string = sandboxGroup.name
output AZURE_SANDBOX_IDENTITY_CLIENT_ID string = sandboxIdentity.properties.clientId
output AZURE_SANDBOX_IDENTITY_PRINCIPAL_ID string = sandboxIdentity.properties.principalId
output AZURE_SANDBOX_IDENTITY_RESOURCE_ID string = sandboxIdentity.id
