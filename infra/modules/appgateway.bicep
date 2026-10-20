// Application Gateway v2 (WAF) with:
//  - HTTP health probe on /health, 15s interval, 3 unhealthy threshold -> ~30s removal
//  - backend pool that the VMSS joins (via vmss.bicep)
//  - access logs to Log Analytics for probe-failure forensics

targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object = {}
param subnetId string
param workspaceId string
param capacity int = 2

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-appgw-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-09-01' = {
  name: '${namePrefix}-appgw'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: capacity
      maxCapacity: 10
    }
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
    }
    sslCertificates: []
    gatewayIPConfigurations: [
      {
        name: 'gwip'
        properties: {
          subnet: { id: subnetId }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'feip'
        properties: {
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
    frontendPorts: [
      { name: 'port80', properties: { port: 80 } }
    ]
    // ---- the health probe is the load-bearing part of self-healing ----
    probes: [
      {
        name: 'probe-health'
        properties: {
          protocol: 'Http'
          path: '/health'
          interval: 15          // seconds between probes
          timeout: 10
          unhealthyThreshold: 3 // 3 x 15s = ~30s to removal
          healthyThreshold: 2
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: ['200']
            body: 'ok'
          }
        }
      }
    ]
    backendAddressPools: [
      { name: 'pool-web' }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'http-web'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: { id: resourceId('Microsoft.Network/applicationGateways/probes', '${namePrefix}-appgw', 'probe-health') }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', '${namePrefix}-appgw', 'feip') }
          frontendPort: { id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', '${namePrefix}-appgw', 'port80') }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule-web'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: resourceId('Microsoft.Network/applicationGateways/httpListeners', '${namePrefix}-appgw', 'listener-http') }
          backendAddressPool: { id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', '${namePrefix}-appgw', 'pool-web') }
          backendHttpSettings: { id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', '${namePrefix}-appgw', 'http-web') }
        }
      }
    ]
  }
}

// Probe failures are the earliest signal that an instance is sick.
resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: appGateway
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'ApplicationGatewayAccessLog', enabled: true }
      { category: 'ApplicationGatewayPerformanceLog', enabled: true }
      { category: 'ApplicationGatewayFirewallLog', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output appGatewayId string = appGateway.id
output backendPoolId string = resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGateway.name, 'pool-web')
output publicHostname string = publicIp.properties.dnsSettings.?fqdn ?? publicIp.properties.ipAddress
output publicIp string = publicIp.properties.ipAddress
