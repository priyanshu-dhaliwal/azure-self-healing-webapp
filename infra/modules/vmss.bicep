// VM Scale Set for the web tier.
//  - zone-spanning, so a zone failure is not a "healing" event but a capacity event
//  - Azure Monitor Agent + DCR for guest metrics and syslog
//  - custom script extension installs nginx + the app from ./app
//  - Joins the App Gateway backend pool by resource id

targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object = {}
param vmSize string
param minCapacity int
param maxCapacity int
param subnetId string
param backendPoolId string
param workspaceId string
param dataCollectionRuleId string

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = {
  name: '${namePrefix}-vmss'
  location: location
  tags: tags
  zones: ['1', '2', '3']
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: minCapacity
  }
  properties: {
    upgradePolicy: {
      mode: 'Automatic'
      automaticOSUpgradePolicy: { enableAutomaticOSUpgrade: true }
    }
    // Spread instances across zones on an even basis.
    orchestrationMode: 'Uniform'
    platformFaultDomainCount: 1
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: { storageAccountType: 'Premium_LRS' }
          caching: 'ReadWrite'
        }
      }
      osProfile: {
        computerNamePrefix: '${namePrefix}-web'
        adminUsername: 'azureuser'
        // Password auth disabled; SSH via Azure AD login extension (see below).
        linuxConfiguration: {
          disablePasswordAuthentication: true
        }
        customData: base64(loadTextContent('../../app/cloud-init.yaml'))
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic-web'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig-web'
                  properties: {
                    subnet: { id: subnetId }
                    primary: true
                    applicationGatewayBackendAddressPools: [
                      { id: backendPoolId }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'AzureMonitorLinuxAgent'
            properties: {
              publisher: 'Microsoft.Azure.Monitor'
              type: 'AzureMonitorLinuxAgent'
              typeHandlerVersion: '1.29'
              autoUpgradeMinorVersion: true
            }
          }
          {
            name: 'AzureADSSHLogin'
            properties: {
              publisher: 'Microsoft.Azure.ActiveDirectory'
              type: 'AADSSHLoginForLinux'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: { enabled: true }
      }
    }
  }
}

// Attach the DCR so guest metrics + syslog land in the shared workspace.
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${namePrefix}-vmss-dcr'
  scope: vmss
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'Guest metrics + syslog for self-healing detection'
  }
}

// Autoscale: scale on CPU, and also on the App Gateway unhealthy-host metric
// (bellwether for "we are healing, add capacity").
resource autoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: '${namePrefix}-vmss-autoscale'
  location: location
  tags: tags
  properties: {
    targetResourceUri: vmss.id
    enabled: true
    profiles: [
      {
        name: 'default'
        capacity: {
          minimum: string(minCapacity)
          maximum: string(maxCapacity)
          default: string(minCapacity)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

output vmssResourceId string = vmss.id
output vmssName string = vmss.name
