#!/usr/bin/env bash
# Print the healing history and MTTR from HealingAudit_CL.
#
#   ./scripts/healing-report.sh              # last 24h
#   ./scripts/healing-report.sh 7d
set -euo pipefail

WINDOW="${1:-24h}"
RG="${RG:-rg-dev-selfhealing-dev01}"
LAW="${LAW:-dev-shw-dev01-law}"
WSID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)

echo "==> Healing audit, last $WINDOW (workspace $LAW)"
az monitor log-analytics query -w "$WSID" --analytics-query "
  HealingAudit_CL
  | where TimeGenerated > ago($WINDOW)
  | project TimeGenerated, InstanceId_s, Action_s, Outcome_s, Trigger_s, DurationSeconds_d, Detail_s
  | order by TimeGenerated desc
" -o table

echo
echo "==> MTTR by action"
az monitor log-analytics query -w "$WSID" --analytics-query "
  HealingAudit_CL
  | where TimeGenerated > ago($WINDOW)
  | where Outcome_s == 'healed'
  | summarize Heals=count(), MTTR_seconds=round(avg(DurationSeconds_d),1),
              P95_seconds=round(percentile(DurationSeconds_d, 95),1)
            by Action_s
  | order by Heals desc
" -o table

echo
echo "==> Effectiveness (healed vs not)"
az monitor log-analytics query -w "$WSID" --analytics-query "
  HealingAudit_CL
  | where TimeGenerated > ago($WINDOW)
  | summarize Count=count() by Outcome_s
  | extend Pct = round(100.0 * Count / toscalar(HealingAudit_CL | where TimeGenerated > ago($WINDOW) | count), 1)
" -o table
