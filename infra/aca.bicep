// Azure Container Apps infrastructure for OpenClaw
// Provisions: VNet, ACR, Log Analytics, ACA Environment (internal),
//             Azure Files storage, Container App, private endpoints
// Uses managed identity (keyless) for Azure OpenAI access
// All resources are network-isolated — no public internet access

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
// Virtual Network — network isolation for all resources
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'aca-subnet'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.0.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

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
// Network-restricted: deny public access, allow only VNet via private endpoint
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${resourceToken}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  tags: { 'azd-env-name': environmentName }
  properties: {
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
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
// Container Apps Environment — internal VNet integration (no public ingress)
// ---------------------------------------------------------------------------
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'env-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
      internal: true
    }
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
        external: false
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
            {
              name: 'OPENAI_BASE_URL'
              value: '${openaiEndpoint}openai/v1/'
            }
            // No OPENAI_API_KEY — the token-refresh wrapper in the container
            // uses DefaultAzureCredential (managed identity) to obtain a bearer
            // token and passes it to OpenClaw at runtime.
            {
              name: 'OPENAI_MODEL_DEPLOYMENT'
              value: openaiDeploymentName
            }
            // Signal to the entrypoint that managed identity auth is active
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
// This is what makes keyless auth work: the container's identity can call Azure
// OpenAI without any API key.
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
// Private DNS Zones — resolve private endpoint FQDNs inside the VNet
// ---------------------------------------------------------------------------
resource openaiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
  tags: { 'azd-env-name': environmentName }
}

resource openaiDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: openaiPrivateDnsZone
  name: 'openai-vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.core.windows.net'
  location: 'global'
  tags: { 'azd-env-name': environmentName }
}

resource storageDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storagePrivateDnsZone
  name: 'storage-vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// ---------------------------------------------------------------------------
// Private Endpoints — Azure OpenAI and Storage are only reachable via VNet
// ---------------------------------------------------------------------------
resource openaiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-openai-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: {
    subnet: { id: vnet.properties.subnets[1].id }
    privateLinkServiceConnections: [
      {
        name: 'openai-link'
        properties: {
          privateLinkServiceId: openaiResourceId
          groupIds: ['account']
        }
      }
    ]
  }
}

resource openaiPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: openaiPrivateEndpoint
  name: 'openai-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'openai-config'
        properties: { privateDnsZoneId: openaiPrivateDnsZone.id }
      }
    ]
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-storage-${resourceToken}'
  location: location
  tags: { 'azd-env-name': environmentName }
  properties: {
    subnet: { id: vnet.properties.subnets[1].id }
    privateLinkServiceConnections: [
      {
        name: 'storage-link'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['file']
        }
      }
    ]
  }
}

resource storagePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: storagePrivateEndpoint
  name: 'storage-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storage-config'
        properties: { privateDnsZoneId: storagePrivateDnsZone.id }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
output CONTAINER_APP_FQDN string = containerApp.properties.configuration.ingress.fqdn
output CONTAINER_APP_NAME string = containerApp.name
