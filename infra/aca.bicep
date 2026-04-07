// Azure Container Apps infrastructure for OpenClaw
// Provisions: ACR, Log Analytics, ACA Environment, Azure Files storage, Container App

param location string
param resourceToken string
param environmentName string

@description('Azure OpenAI endpoint (e.g. https://<name>.openai.azure.com/)')
param openaiEndpoint string

@secure()
@description('Azure OpenAI API key')
param openaiKey string

@description('Azure OpenAI model deployment name')
param openaiDeploymentName string

// ---------------------------------------------------------------------------
// Azure Container Registry
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${resourceToken}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: true }
  tags: { 'azd-env-name': environmentName }
}

// ---------------------------------------------------------------------------
// Azure Storage — persistent state for OpenClaw (credentials, workspace, sessions)
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${resourceToken}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  tags: { 'azd-env-name': environmentName }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
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
// ---------------------------------------------------------------------------
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'env-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: {
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
resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: environment
  name: 'openclawstate'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// Container App — OpenClaw gateway
// ---------------------------------------------------------------------------
// NOTE: azd deploy replaces the placeholder image with the custom build from src/Dockerfile.
// Future iteration: enable system-assigned managed identity for keyless Azure OpenAI access.
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'openclaw-${resourceToken}'
  location: location
  // TODO (future): uncomment to enable managed identity for keyless auth
  // identity: { type: 'SystemAssigned' }
  tags: {
    'azd-env-name': environmentName
    'azd-service-name': 'openclaw'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      secrets: [
        // TODO (future): remove API key secret once managed identity is active
        {
          name: 'openai-api-key'
          value: openaiKey
        }
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      ingress: {
        external: true
        targetPort: 18789
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'openclaw'
          // Placeholder; azd deploy overwrites with the built image
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('2.0')
            memory: '4Gi'
          }
          env: [
            // Azure OpenAI v1 endpoint — fully OpenAI-SDK-compatible
            // Redirects openclaw's native OpenAI integration to Azure OpenAI
            {
              name: 'OPENAI_BASE_URL'
              value: '${openaiEndpoint}openai/v1/'
            }
            // API key (current); future: use DefaultAzureCredential via managed identity
            {
              name: 'OPENAI_API_KEY'
              secretRef: 'openai-api-key'
            }
            {
              name: 'OPENAI_MODEL_DEPLOYMENT'
              value: openaiDeploymentName
            }
          ]
          volumeMounts: [
            {
              volumeName: 'state-volume'
              mountPath: '/mnt/state'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'state-volume'
          storageName: envStorage.name
          storageType: 'AzureFile'
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// TODO (future): Assign Cognitive Services User role to the Container App's managed identity
// This removes the need for API keys entirely.
//
// resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
//   name: guid(subscription().id, containerApp.id, 'a97b65f3-24c7-4388-baec-2e87135dc908')
//   scope: <openaiResource>
//   properties: {
//     principalId: containerApp.identity.principalId
//     roleDefinitionId: subscriptionResourceId(
//       'Microsoft.Authorization/roleDefinitions',
//       'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
//     )
//     principalType: 'ServicePrincipal'
//   }
// }

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
output CONTAINER_APP_FQDN string = containerApp.properties.configuration.ingress.fqdn
output CONTAINER_APP_NAME string = containerApp.name
