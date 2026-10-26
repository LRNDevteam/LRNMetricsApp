// AR Workbench documents (PHI) - HIPAA-compliant Azure Blob Storage.
// Deploy to resource group lrn-reporting-apps (the resource group of kv-lrnmetrics-prod):
//   az deployment group what-if -g lrn-reporting-apps -f infra/arwb-document-storage/arwb-document-storage.bicep -p @infra/arwb-document-storage/arwb-document-storage.parameters.json
//   az deployment group create  -g lrn-reporting-apps -f infra/arwb-document-storage/arwb-document-storage.bicep -p @infra/arwb-document-storage/arwb-document-storage.parameters.json
// Before the first deployment: purge protection on the vault; Microsoft.Security and Microsoft.EventGrid
// providers registered; private endpoint subnet and privatelink.blob.core.windows.net zone in place.
// Each resource notes the 45 CFR section it serves.

targetScope = 'resourceGroup'

@description('Azure region.')
param location string = 'eastus'

@description('Storage account name (3-24 lowercase letters and digits).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stlrnarwbphi'

@description('Blob container for AR Workbench documents (ArWorkbenchDocuments:ContainerName).')
param containerName string = 'arwb-documents'

@description('Existing Key Vault that holds the customer-managed key (must have purge protection on).')
param keyVaultName string = 'kv-lrnmetrics-prod'

@description('Name of the customer-managed key created in the vault.')
param cmkKeyName string = 'cmk-arwb-documents'

@description('Resource ID of the subnet (in the API VNet) for the blob private endpoint.')
param privateEndpointSubnetId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneId string

@description('Resource ID of the Log Analytics workspace (reimbursement-agent-logs).')
param logAnalyticsWorkspaceId string

@description('Object (principal) ID of the API managed identity that reads and writes documents.')
param apiPrincipalId string

@description('Days documents and their versions are kept (HIPAA documentation minimum is 6 years = 2190 days).')
@minValue(2190)
param retentionDays int = 3650

@description('Defender for Storage malware scanning cap per month, in GB.')
param malwareScanCapGbPerMonth int = 1000

// Built-in role IDs.
var keyVaultCryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// 164.312(a)(2)(iv) encryption at rest: customer-managed key, rotated automatically every 2 years.
resource cmkKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: cmkKeyName
  properties: {
    kty: 'RSA'
    keySize: 3072
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    rotationPolicy: {
      attributes: {
        expiryTime: 'P2Y'
      }
      lifetimeActions: [
        {
          trigger: {
            timeBeforeExpiry: 'P60D'
          }
          action: {
            type: 'rotate'
          }
        }
        {
          trigger: {
            timeBeforeExpiry: 'P30D'
          }
          action: {
            type: 'notify'
          }
        }
      ]
    }
  }
}

// The identity the storage account uses to wrap / unwrap its key.
resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${storageAccountName}-cmk'
  location: location
}

resource storageIdentityKeyAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, storageIdentity.id, keyVaultCryptoServiceEncryptionUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoServiceEncryptionUserRoleId)
    principalId: storageIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// 164.312(a)(1) access control, 164.312(d) authentication, 164.312(e)(1) transmission security,
// 164.308(a)(7) contingency (RA-GZRS): private only, Entra ID only, TLS 1.2, double encryption.
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_RAGZRS'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${storageIdentity.id}': {}
    }
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    encryption: {
      keySource: 'Microsoft.Keyvault'
      requireInfrastructureEncryption: true
      identity: {
        userAssignedIdentity: storageIdentity.id
      }
      keyvaultproperties: {
        // Versionless: the account follows the key's automatic rotation.
        keyname: cmkKey.name
        keyvaulturi: keyVault.properties.vaultUri
      }
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
  dependsOn: [
    storageIdentityKeyAccess
  ]
}

// 164.308(a)(7): the account cannot be deleted while the lock is in place.
resource storageLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: '${storageAccountName}-nodelete'
  scope: storage
  properties: {
    level: 'CanNotDelete'
    notes: 'Holds AR Workbench PHI documents (HIPAA retention). Remove only with Compliance approval.'
  }
}

// 164.312(c)(1) integrity, 164.308(a)(7) contingency: versions, soft delete, point-in-time restore.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 2190
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 30
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    restorePolicy: {
      enabled: true
      days: 29
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// 164.316(b)(2)(i) retention: cool after 90 days, delete only after retentionDays.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'arwb-documents-retention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${containerName}/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: retentionDays
                }
              }
              version: {
                delete: {
                  daysAfterCreationGreaterThan: retentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    container
  ]
}

// 164.312(a)(1) / 164.312(e)(1): reachable only from the API VNet.
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

// 164.312(b) audit controls: every read, write and delete to Log Analytics.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'arwb-documents-audit'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

// 164.308(a)(5)(ii)(B) malware protection: every upload is scanned; the result is written to the
// blob index tag "Malware Scanning scan result", which the API checks before each download.
resource defender 'Microsoft.Security/defenderForStorageSettings@2022-12-01-preview' = {
  name: 'current'
  scope: storage
  properties: {
    isEnabled: true
    overrideSubscriptionLevelSettings: true
    malwareScanning: {
      onUpload: {
        isEnabled: true
        capGBPerMonth: malwareScanCapGbPerMonth
      }
    }
    sensitiveDataDiscovery: {
      isEnabled: true
    }
  }
}

// Least privilege: the API identity gets data access on this one container only.
resource apiBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, apiPrincipalId, storageBlobDataContributorRoleId)
  scope: container
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Reading the Defender scan tag needs blobs/tags/read, which the role above does not grant.
resource tagReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'arwb-blob-tag-reader')
  properties: {
    roleName: 'AR Workbench Blob Tag Reader (${resourceGroup().name})'
    description: 'Reads blob index tags (Defender for Storage malware scan result) for AR Workbench documents.'
    type: 'CustomRole'
    assignableScopes: [
      resourceGroup().id
    ]
    permissions: [
      {
        actions: []
        notActions: []
        dataActions: [
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'
        ]
        notDataActions: []
      }
    ]
  }
}

resource apiTagRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, apiPrincipalId, tagReaderRole.id)
  scope: container
  properties: {
    roleDefinitionId: tagReaderRole.id
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

@description('ArWorkbenchDocuments:BlobServiceUri (Key Vault secret ArWorkbenchDocuments--BlobServiceUri).')
output blobServiceUri string = storage.properties.primaryEndpoints.blob

@description('ArWorkbenchDocuments:ContainerName.')
output containerName string = container.name
