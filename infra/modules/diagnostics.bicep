// Diagnostics for the VMSS itself (instance-level metrics to the shared workspace)
// and a small "platform health" summary that the workbook can bind to.

targetScope = 'resourceGroup'

param namePrefix string
param workspaceId string
param appGatewayId string

// NOTE: VMSS extension/guest diagnostics are handled by the DCR association in
// vmss.bicep. Platform-level metrics go here so the workbook has a single scope.
resource vmssPlatformDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'vmss-platform-to-law'
  scope: resourceGroup()
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Administrative', enabled: true }
      { category: 'Security', enabled: true }
      { category: 'Alert', enabled: true }
    ]
  }
}
