// Azure Container Apps infrastructure for OpenClaw (Express — no VNet)
// Provisions: ACR, Log Analytics, ACA Environment, Azure Files, Container App
// Uses managed identity (keyless) for Azure OpenAI access
// Scale-to-zero enabled — no compute charges when idle

param location string
param resourceToken string
param environmentName string

@description('Azure OpenAI endpoint (e.g. https://<name>.openai.azure.com/)')
param openaiEndpoint string

@description('Azure OpenAI model deployment name')
param openaiDeploymentName string

@description('Azure OpenAI resource ID (for role assignment scoping)')
param openaiResourceId string

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
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
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
// Container Apps Environment (no VNet — fast provisioning, instant cold start)
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
// Container App — OpenClaw gateway (keyless via managed identity)
// Scale-to-zero: no compute charges when idle
// ---------------------------------------------------------------------------
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'openclaw-${resourceToken}'
  location: location
  identity: { type: 'SystemAssigned' }
  tags: {
    'azd-env-name': environmentName
    'azd-service-name': 'openclaw'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      secrets: [
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
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          // Startup probe: give OpenClaw up to 5 min to boot (token acquisition + gateway init)
          probes: [
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
          env: [
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

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
output CONTAINER_APP_FQDN string = containerApp.properties.configuration.ingress.fqdn
output CONTAINER_APP_NAME string = containerApp.name
