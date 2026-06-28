// Azure Container Apps infrastructure for OpenClaw
// Provisions: ACR, Log Analytics, ACA Environment, Azure Files, Container App
// Uses managed identity (keyless) for Azure OpenAI access
// Scale-to-zero enabled — no compute charges when idle

param location string
param resourceToken string
param environmentName string

@description('Opt into ACA Express mode (preview). When true, the managed env is created with environmentMode=Express. Only enable in regions where Express is supported.')
param useExpressEnv bool = false

@description('Azure OpenAI endpoint (e.g. https://<name>.openai.azure.com/)')
param openaiEndpoint string

@description('Azure OpenAI model deployment name')
param openaiDeploymentName string

@description('Azure OpenAI resource ID (for role assignment scoping)')
param openaiResourceId string

@description('Bot App Registration ID (from preprovision hook)')
param botAppId string = ''

@description('Bot App Registration Secret')
@secure()
param botAppSecret string = ''

@description('Bot Tenant ID')
param botTenantId string = ''

@description('Easy Auth App Registration ID (for Entra ID login gate)')
param easyAuthAppId string = ''

@description('Container image to deploy. azd populates this from SERVICE_OPENCLAW_IMAGE_NAME after the first `azd deploy`; empty on first provision so a placeholder is used.')
param containerImage string = ''

@description('When true, skip the storage account + Azure Files volume mount. Use on subscriptions where Azure Policy blocks `allowSharedKeyAccess: true` on storage accounts (ACA file mounts require shared keys today). Set SKIP_STORAGE=true in your azd env. Trade-off: gateway token + sessions do not persist across replica restarts.')
param skipStorage bool = false

@description('Execution mode for the Gateway. inproc = today\'s single-container behavior. sandbox = offload untrusted tool execution to ephemeral ACA Sandboxes via the sandbox MCP server. Worker/disk/snapshot ids are added to the container by the post-provision hook (they only exist after the image is built).')
param executionMode string = 'inproc'

@description('Sandbox group name the Gateway drives when executionMode=sandbox (deterministic; the execution module creates a group with this name).')
param sandboxGroupName string = ''

@description('Worker MI client-id for keyless Azure OpenAI from sandboxes. Empty on first provision; the post-provision hook fills it.')
param workerIdentityClientId string = ''

@description('Execution image / disk / snapshot ids. Empty on first provision; the post-provision hook builds them and updates the container.')
param execAcrImage string = ''
param execImageDigest string = ''
param execDiskId string = ''
param execSnapshot string = ''

// Teams integration is opt-in. The preprovision hook only creates the Bot
// app registration when `azd env set ENABLE_TEAMS true` is set, so an empty
// botAppId is the canonical "Teams disabled" signal.
var teamsEnabled = !empty(botAppId)

// Storage is mounted via Azure Files when both standard env mode and the
// shared-key-allowed storage account are in play. Express mode and the
// SKIP_STORAGE escape hatch both turn it off.
var storageEnabled = !useExpressEnv && !skipStorage

// Build the container `secrets` array conditionally so we never emit an empty
// `msteams-app-password` secret value (which ACA rejects) when Teams is off.
// ACR is pulled via managed identity (AcrPull role below) — no admin
// password secret is needed and admin user is disabled on the registry to
// satisfy the common 'Container registries should have local admin account
// disabled' Azure Policy.
var teamsSecrets = teamsEnabled ? [
  {
    name: 'msteams-app-password'
    value: botAppSecret
  }
] : []
var containerSecrets = teamsSecrets

// Build the container env block conditionally for the same reason — when
// Teams is disabled, none of the MSTEAMS_* placeholders should be injected.
var baseEnv = [
  {
    name: 'OPENAI_BASE_URL'
    value: '${openaiEndpoint}openai/v1/'
  }
  {
    name: 'OPENAI_MODEL_DEPLOYMENT'
    value: openaiDeploymentName
  }
  {
    name: 'AZURE_OPENAI_AUTH'
    value: 'managed-identity'
  }
]
var teamsEnv = teamsEnabled ? [
  {
    name: 'MSTEAMS_APP_ID'
    value: botAppId
  }
  {
    name: 'MSTEAMS_APP_PASSWORD'
    secretRef: 'msteams-app-password'
  }
  {
    name: 'MSTEAMS_TENANT_ID'
    value: botTenantId
  }
] : []
// Execution layer: the *known* config the sandbox MCP server needs. The
// worker MI client-id + EXEC_DISK_ID/EXEC_SNAPSHOT are injected by the
// post-provision hook (they only exist after the execution image is built),
// which avoids a Bicep module cycle between the Gateway and the group.
var sandboxEnabled = toLower(executionMode) == 'sandbox'
var executionEnv = sandboxEnabled ? [
  { name: 'EXECUTION_MODE', value: 'sandbox' }
  { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
  { name: 'AZURE_RESOURCE_GROUP', value: resourceGroup().name }
  { name: 'AZURE_SANDBOX_GROUP_NAME', value: sandboxGroupName }
  { name: 'AZURE_LOCATION', value: location }
  { name: 'SANDBOX_MANAGED_IDENTITY', value: 'system' }
  { name: 'SANDBOX_DRIVER', value: 'cli' }
  { name: 'STARTUP', value: 'snapshot' }
  { name: 'WORKER_IDENTITY_CLIENT_ID', value: workerIdentityClientId }
  { name: 'EXEC_ACR_IMAGE', value: execAcrImage }
  { name: 'EXEC_IMAGE_DIGEST', value: execImageDigest }
  { name: 'EXEC_DISK_ID', value: execDiskId }
  { name: 'EXEC_SNAPSHOT', value: execSnapshot }
] : []
var containerEnv = concat(baseEnv, teamsEnv, executionEnv)

// ---------------------------------------------------------------------------
// Azure Container Registry — admin disabled (common Azure Policy), pulled via
// the container app's system-assigned managed identity + AcrPull role below.
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${resourceToken}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
  tags: { 'azd-env-name': environmentName }
}

// User-assigned identity for ACR pulls, granted AcrPull BEFORE the container
// app exists. This breaks the first-provision deadlock where ACA needs to
// build the registry secret (to provision the revision) before the system MI's
// AcrPull role has been created — the container app references this identity in
// its `registries` block, and the role below has no dependency on the app.
resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-acrpull-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
}

resource acrPullIdentityRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, acrPullIdentity.id, acr.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: acrPullIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Azure Storage — persistent state for OpenClaw (credentials, workspace, sessions)
// Skipped when SKIP_STORAGE=true (e.g. when Azure Policy blocks shared-key
// access — ACA file mounts require shared keys today) or in Express mode.
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = if (storageEnabled) {
  name: 'st${resourceToken}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  tags: { 'azd-env-name': environmentName }
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = if (storageEnabled) {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (storageEnabled) {
  parent: fileServices
  name: 'openclaw-state'
  properties: { shareQuota: 5 }
}

// ---------------------------------------------------------------------------
// Log Analytics workspace (required by ACA)
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${resourceToken}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
  tags: { 'azd-env-name': environmentName }
}

// ---------------------------------------------------------------------------
// Container Apps Environment
// When useExpressEnv is true → Express mode (preview, fast cold start, no VNet).
//   Express does NOT support appLogsConfiguration — logs flow through platform defaults.
// Otherwise → standard Consumption-only env wired to the Log Analytics workspace above.
// ---------------------------------------------------------------------------
resource environment 'Microsoft.App/managedEnvironments@2026-03-02-preview' = {
  name: 'env-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: useExpressEnv ? {
    environmentMode: 'Express'
  } : {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Mount Azure Files into the ACA environment
// Skipped when storage is disabled (Express mode OR SKIP_STORAGE=true).
// (Trade-off when off: gateway token + sessions persist only for the lifetime of a replica.)
resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = if (storageEnabled) {
  parent: environment
  name: 'openclawstate'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      // storageAccount and envStorage share the same condition (storageEnabled),
      // so this listKeys() is only reached when storageAccount exists.
      #disable-next-line BCP422
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// Container App — OpenClaw gateway (keyless via managed identity)
// Scale-to-zero: no compute charges when idle
// ---------------------------------------------------------------------------

// Preserve the image that `azd deploy` pushed on prior runs by reading it
// from the `containerImage` parameter (sourced from SERVICE_OPENCLAW_IMAGE_NAME
// in main.parameters.json). On first provision the param is empty, so we fall
// back to a placeholder; subsequent provisions retain whatever azd last pushed.
//
// Placeholder vs. real image is also the deciding factor for the listen port:
// `mcr.microsoft.com/k8se/quickstart:latest` listens on :80, OpenClaw on :18789.
// On first provision we ingress to :80 with no probes (so the container is
// healthy immediately and `azd provision` doesn't time out waiting for a
// port nobody is listening on). The postdeploy hook flips ingress to :18789
// after the first real `azd deploy` lands.
var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var isPlaceholder = empty(containerImage)
var effectiveImage = isPlaceholder ? placeholderImage : containerImage
var appPort = isPlaceholder ? 80 : 18789

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'openclaw-${resourceToken}'
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentity.id}': {}
    }
  }
  tags: {
    'azd-env-name': environmentName
    'azd-service-name': 'openclaw'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      secrets: containerSecrets
      registries: [
        {
          server: acr.properties.loginServer
          // Pull via the pre-granted user-assigned identity (id-acrpull) so the
          // revision can be provisioned without waiting on a role assignment
          // that depends on this very container app (the first-provision race).
          identity: acrPullIdentity.id
        }
      ]
      ingress: {
        external: true
        targetPort: appPort
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'openclaw'
          image: effectiveImage
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          // Skip probes when running the placeholder image — it listens on
          // :80, not :18789, so probing :18789 would loop fail/restart for
          // the full provision window. Real image gets full probe coverage.
          probes: isPlaceholder ? [] : [
            {
              type: 'Startup'
              tcpSocket: {
                port: 18789
              }
              initialDelaySeconds: 10
              periodSeconds: 5
              failureThreshold: 60
              timeoutSeconds: 3
            }
            {
              type: 'Liveness'
              tcpSocket: {
                port: 18789
              }
              periodSeconds: 30
              failureThreshold: 3
              timeoutSeconds: 3
            }
          ]
          env: containerEnv
          volumeMounts: storageEnabled ? [
            {
              volumeName: 'state-volume'
              mountPath: '/mnt/state'
            }
          ] : []
        }
      ]
      volumes: storageEnabled ? [
        {
          name: 'state-volume'
          storageName: envStorage.name
          storageType: 'AzureFile'
        }
      ] : []
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Easy Auth — Entra ID login gate (requires Microsoft login before any request)
// Only deployed if easyAuthAppId is provided by the preprovision hook
// ---------------------------------------------------------------------------
resource containerAppAuth 'Microsoft.App/containerApps/authConfigs@2024-03-01' = if (!empty(easyAuthAppId)) {
  parent: containerApp
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      // Bot Framework Connector posts to /api/messages with its own JWT.
      // When Teams is enabled, Easy Auth must NOT intercept this path or
      // bot replies silently fail. When Teams is off, no carve-out is added.
      excludedPaths: teamsEnabled ? [
        '/api/messages'
      ] : []
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: easyAuthAppId
          openIdIssuer: 'https://sts.windows.net/${subscription().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${easyAuthAppId}'
          ]
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC — Assign Cognitive Services User to the Container App's managed identity
// ---------------------------------------------------------------------------
resource openaiResource 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(openaiResourceId, '/'))
}

resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, containerApp.id, 'a97b65f3-24c7-4388-baec-2e87135dc908')
  scope: openaiResource
  properties: {
    principalId: containerApp.identity.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
    )
    principalType: 'ServicePrincipal'
  }
}

// ACR pull is handled by the pre-granted `id-acrpull` user-assigned identity
// (see acrPullIdentityRole near the registry, created before the container app
// to avoid the first-provision deadlock). No system-MI AcrPull role here.

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
// Host outputs — named generically so the underlying compute can change
// (e.g. AKS, App Service) without updating callers or azd env consumers.
output HOST_FQDN string = containerApp.properties.configuration.ingress.fqdn
output HOST_NAME string = containerApp.name
output HOST_PRINCIPAL_ID string = containerApp.identity.principalId

// ---------------------------------------------------------------------------
// Azure Bot Service (optional — only deployed if botAppId is provided)
// Uses the Entra ID app registration created by the preprovision hook
// ---------------------------------------------------------------------------
resource bot 'Microsoft.BotService/botServices@2022-09-15' = if (!empty(botAppId)) {
  name: 'bot-${resourceToken}'
  location: 'global'
  kind: 'azurebot'
  sku: { name: 'F0' }
  tags: { 'azd-env-name': environmentName }
  properties: {
    displayName: 'OpenClaw'
    description: 'OpenClaw AI assistant on Azure'
    endpoint: 'https://${containerApp.properties.configuration.ingress.fqdn}/api/messages'
    msaAppId: botAppId
    msaAppType: 'SingleTenant'
    msaAppTenantId: botTenantId
  }
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = if (!empty(botAppId)) {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
    }
  }
}

output BOT_APP_ID string = botAppId
