// Composition root for the self-healing web app.
// Deploy with: az deployment sub create --location <region> --template-file infra/main.bicep --parameters infra/params/dev.bicepparam

targetScope = 'subscription'

@description('Environment name: dev | prod')
@allowed(['dev', 'prod'])
param env string = 'dev'

@description('Primary Azure region')
param location string = resourceGroup().location

@description('Short suffix for globally-unique names')
@minLength(3)
@maxLength(8)
param suffix string = 'shw'

@description('VM size for the web tier')
param vmSize string = 'Standard_B2s'

@description('Minimum instance count in the scale set')
param minCapacity int = 2

@description('Maximum instance count in the scale set')
param maxCapacity int = 6

@description('Email address for human alerts')
param alertEmail string

@description('Tags applied to every resource')
param tags object = {
  project: 'self-healing-webapp'
  owner: 'platform'
}

var rgName = 'rg-${env}-selfhealing-${suffix}'
var namePrefix = '${env}-shw-${suffix}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: tags
}

module network './modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
  }
}

module monitoring './modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    alertEmail: alertEmail
    env: env
  }
}

module automation './modules/automation.bicep' = {
  scope: rg
  name: 'automation'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    vmssResourceId: vmss.outputs.vmssResourceId
    env: env
  }
}

module appGateway './modules/appgateway.bicep' = {
  scope: rg
  name: 'appgateway'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    subnetId: network.outputs.appGatewaySubnetId
    workspaceId: monitoring.outputs.workspaceId
  }
}

module vmss './modules/vmss.bicep' = {
  scope: rg
  name: 'vmss'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    vmSize: vmSize
    minCapacity: minCapacity
    maxCapacity: maxCapacity
    subnetId: network.outputs.webSubnetId
    backendPoolId: appGateway.outputs.backendPoolId
    workspaceId: monitoring.outputs.workspaceId
    dataCollectionRuleId: monitoring.outputs.dataCollectionRuleId
  }
}

// Alert rules need the VMSS resource id, so they live in a second monitoring pass.
module alerts './modules/alerts.bicep' = {
  scope: rg
  name: 'alerts'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    vmssResourceId: vmss.outputs.vmssResourceId
    healingActionGroupId: monitoring.outputs.healingActionGroupId
    notifyActionGroupId: monitoring.outputs.notifyActionGroupId
  }
}

module diagnostic './modules/diagnostics.bicep' = {
  scope: rg
  name: 'diagnostics'
  params: {
    namePrefix: namePrefix
    workspaceId: monitoring.outputs.workspaceId
    appGatewayId: appGateway.outputs.appGatewayId
  }
}

output resourceGroupName string = rg.name
output publicHostname string = appGateway.outputs.publicHostname
output vmssName string = vmss.outputs.vmssName
output workspaceName string = monitoring.outputs.workspaceName
