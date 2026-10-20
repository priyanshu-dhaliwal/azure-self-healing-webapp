// Alert rules. Two severities, two action groups:
//
//  SEV2 -> notify only  (guest heartbeat missing once, or app returns 5xx)
//  SEV1 -> heal + notify (instance unavailable, or 5xx sustained for 5m)
//
// Every rule carries the instance dimension so the runbook can target
// precisely one instance instead of whole-scale-set surgery.

targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object = {}
param vmssResourceId string
param healingActionGroupId string
param notifyActionGroupId string

// 1) VMSS instance-level availability: fires when Azure sees an instance
//    that has not reported a heartbeat in 5 minutes.
resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-alert-instance-unavailable'
  location: 'global'
  tags: tags
  properties: {
    description: 'A VMSS instance has stopped reporting a heartbeat — runbook will reimage it.'
    severity: 1
    enabled: true
    scopes: [vmssResourceId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': '#Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'VmAvailabilityMetric'
          metricName: 'VmAvailabilityMetric'
          metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: healingActionGroupId
        webHookProperties: {
          runbook: 'Heal-ReimageInstance'
          action: 'reimage'
          lockScope: 'instance'
        }
      }
      {
        actionGroupId: notifyActionGroupId
      }
    ]
  }
}

// 2) Guest heartbeat via Log Analytics — catches the case where the host is up
//    but the agent/app is dead (a reimage would be overkill).
resource heartbeatAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-alert-heartbeat-missing'
  location: location
  tags: tags
  properties: {
    displayName: 'Guest heartbeat missing (${namePrefix})'
    description: 'An instance has not sent a heartbeat for 10 minutes. Restart before reimage.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [vmssResourceId]
    criteria: {
      allOf: [
        {
          query: '''
            heartbeat
            | where TimeGenerated > ago(10m)
            | summarize LastSeen = max(TimeGenerated) by Computer, _ResourceId
            | extend MinutesSince = datetime_diff('minute', now(), LastSeen)
            | where MinutesSince > 10
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
          dimensions: [
            { name: 'Computer', operator: 'Include', values: ['*'] }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [healingActionGroupId]
      customProperties: {
        runbook: 'Heal-RestartVmss'
        action: 'restart'
      }
    }
  }
}

// 3) Application-layer: gateway 5xx rate sustained. Catches "instance is up but
//    throwing" — the case a host-level alert misses entirely.
resource fiveHundredsAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-alert-5xx-sustained'
  location: location
  tags: tags
  properties: {
    displayName: '5xx sustained (${namePrefix})'
    description: 'More than 10 gateway 5xx responses per 5 minutes for 10 minutes.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [vmssResourceId]
    criteria: {
      allOf: [
        {
          query: '''
            AzureDiagnostics
            | where ResourceType == "APPLICATIONGATEWAYS"
            | where httpStatus_d between (500 .. 599)
            | summarize ServerErrors = count() by bin(TimeGenerated, 5m)
            | where ServerErrors > 10
            | order by TimeGenerated desc
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [notifyActionGroupId]
    }
  }
}

// 4) Watchdog on the healer itself: if the automation account is failing,
//    humans must be told, because self-healing has stopped self-healing.
resource healingFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-alert-healing-failed'
  location: location
  tags: tags
  properties: {
    displayName: 'Healing runbook failed (${namePrefix})'
    description: 'A healing action reported outcome=failed or timeout. Human intervention likely required.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [vmssResourceId]
    criteria: {
      allOf: [
        {
          query: '''
            HealingAudit_CL
            | where TimeGenerated > ago(15m)
            | where Outcome_s in ("failed", "timeout", "lock-held")
            | project TimeGenerated, InstanceId_s, Action_s, Outcome_s, Detail_s
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 2
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [notifyActionGroupId]
    }
  }
}
