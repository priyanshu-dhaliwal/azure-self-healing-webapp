// Automation Account, PowerShell runbooks, the schedule, and the role
// assignments that let the runbooks do their job — scoped to the VMSS only.
//
// The key security property: the automation identity has NO rights outside the
// resource group's VMSS resource. It cannot touch the network, monitoring or
// its own automation account.

targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object = {}
param workspaceId string
param vmssResourceId string
param env string

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: '${namePrefix}-aa'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

// Required modules for the runbooks.
resource azAccountsModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Accounts'
  properties: {
    contentLink: { uri: 'https://psg-prod-eastus.azureedge.net/packages/az.accounts.3.0.0.nupkg' }
  }
}

resource azComputeModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Compute'
  properties: {
    contentLink: { uri: 'https://psg-prod-eastus.azureedge.net/packages/az.compute.7.2.0.nupkg' }
  }
}

resource azMonitorModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Monitor'
  properties: {
    contentLink: { uri: 'https://psg-prod-eastus.azureedge.net/packages/az.monitor.5.3.0.nupkg' }
  }
}

resource azOperationalInsightsModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.OperationalInsights'
  properties: {
    contentLink: { uri: 'https://psg-prod-eastus.azureedge.net/packages/az.operationalinsights.5.2.0.nupkg' }
  }
}

// ---- Runbooks (inline PowerShell; source also kept under scripts/ for review)

resource reimageRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Heal-ReimageInstance'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: true
    publishContentLink: {
      uri: uri('https://raw.githubusercontent.com/priyanshu-dhaliwal/azure-self-healing-webapp/main/scripts/runbooks/Heal-ReimageInstance.ps1')
    }
  }
  dependsOn: [azAccountsModule, azComputeModule]
}

resource restartRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Heal-RestartVmss'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: true
    publishContentLink: {
      uri: uri('https://raw.githubusercontent.com/priyanshu-dhaliwal/azure-self-healing-webapp/main/scripts/runbooks/Heal-RestartVmss.ps1')
    }
  }
  dependsOn: [azAccountsModule, azComputeModule]
}

// ---- Least-privilege role assignment -------------------------------------

// Built-in "Virtual Machine Contributor", scoped to the VMSS resource only.
resource vmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, vmssResourceId, 'vm-contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Self-healing runbooks: manage VMSS instances only'
  }
}

// Log Analytics Data Collector, so runbooks can write the audit trail.
resource lawCollector 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, workspaceId, 'law-collector')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '59d10477-9431-4d00-9293-d44e5174795d')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Self-healing runbooks: write HealingAudit_CL'
  }
}

output automationAccountId string = automationAccount.id
output automationPrincipalId string = automationAccount.identity.principalId
output reimageRunbookName string = reimageRunbook.name
output restartRunbookName string = restartRunbook.name
