// VNet, subnets and NSGs. Three subnets:
//  - snet-web        : VMSS instances (egress only, no inbound)
//  - snet-appgw      : Application Gateway (requires the AppGatewaySubnet delegation)
//  - snet-automation : (optional) private endpoint target for the Automation account

targetScope = 'resourceGroup'

@description('Prefix for all resource names')
param namePrefix string

param location string
param tags object = {}
param vnetAddressSpace string = '10.42.0.0/16'

resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg-web'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-AppGateway-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRanges: ['80']
        }
      }
      {
        name: 'Allow-HealthProbe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRanges: ['80']
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg-appgw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-HTTP-Internet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-AppGatewayManager'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressSpace]
    }
    subnets: [
      {
        name: 'snet-web'
        properties: {
          addressPrefix: '10.42.1.0/24'
          networkSecurityGroup: { id: nsgWeb.id }
        }
      }
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '10.42.2.0/24'
          networkSecurityGroup: { id: nsgAppGw.id }
        }
      }
    ]
  }
}

resource webSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: vnet
  name: 'snet-web'
  properties: {
    addressPrefix: '10.42.1.0/24'
    networkSecurityGroup: { id: nsgWeb.id }
  }
}

resource appGwSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: vnet
  name: 'snet-appgw'
  properties: {
    addressPrefix: '10.42.2.0/24'
    networkSecurityGroup: { id: nsgAppGw.id }
  }
}

output vnetId string = vnet.id
output webSubnetId string = webSubnet.id
output appGatewaySubnetId string = appGwSubnet.id
output nsgWebId string = nsgWeb.id
