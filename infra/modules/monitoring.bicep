// Log Analytics workspace, data collection rule for guest telemetry,
// and the two action groups (one heals, one notifies a human).

targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object = {}
param alertEmail string
param env string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: env == 'prod' ? 90 : 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Custom table for the healing audit trail. Created by the runbooks on first
// write, but declared here so retention and schema are owned by IaC.
resource healingAuditTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: 'HealingAudit_CL'
  properties: {
    schema: {
      name: 'HealingAudit_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'InstanceId_s', type: 'string' }
        { name: 'Action_s', type: 'string' }          // reimage | restart | redeploy | scaleout | skipped
        { name: 'Outcome_s', type: 'string' }         // healed | failed | timeout | lock-held
        { name: 'Trigger_s', type: 'string' }         // alert rule that fired
        { name: 'DurationSeconds_d', type: 'real' }
        { name: 'RunbookId_s', type: 'string' }
        { name: 'Detail_s', type: 'string' }
      ]
    }
    retentionInDays: env == 'prod' ? 90 : 30
  }
}

// DCR: guest performance counters + syslog, one association per VMSS.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${namePrefix}-dcr'
  location: location
  tags: tags
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(_Total)\\% Free Space'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslog'
          streams: ['Microsoft-Syslog']
          facilityNames: ['daemon', 'syslog', 'kern']
          logLevels: ['Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
      logFiles: [
        {
          name: 'nginxError'
          streams: ['Microsoft-Nginx.Custom']
          filePatterns: ['/var/log/nginx/error.log']
          format: 'text'
          settings: {}
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'lawDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Perf', 'Microsoft-Syslog']
        destinations: ['lawDest']
      }
    ]
  }
}

// ---- Action groups -------------------------------------------------------

resource healingActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-ag-heal'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'shw-heal'
    enabled: true
    automationRunbookReceivers: []   // populated by alerts.bicep once runbooks exist
  }
}

resource notifyActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-ag-notify'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'shw-notify'
    enabled: true
    emailReceivers: [
      {
        name: 'primary-oncall'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output dataCollectionRuleId string = dcr.id
output healingActionGroupId string = healingActionGroup.id
output notifyActionGroupId string = notifyActionGroup.id
