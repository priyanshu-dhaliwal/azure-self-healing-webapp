# Runbook: when self-healing fails

This is the *human* runbook. It exists because the worst failure mode of an
automated healing system is that it fails quietly and everyone assumes it is
still working.

## Alert: "Healing runbook failed" (SEV1)

The `HealingAudit_CL` table has more than 2 rows with `Outcome_s in
("failed","timeout","lock-held")` in the last 15 minutes.

### 1. Confirm the blast radius (60 seconds)

```kusto
HealingAudit_CL
| where TimeGenerated > ago(30m)
| summarize count() by InstanceId_s, Outcome_s
| order by count_ desc
```

One instance → isolated. Several instances → stop and go to §4; you are
probably looking at a bad image or a platform issue, not a sick node.

### 2. Check whether the app or the host is broken

```bash
az vmss list-instances -g <rg> -n <vmss> \
  --query "[].{id:instanceId, state:provisioningState}" -o table

az vmss run-command invoke -g <rg> -n <vmss> --instance-id <id> \
  --command-id RunShellScript \
  --scripts 'curl -s -m 5 -w "\n%{http_code}\n" http://127.0.0.1:8080/health; systemctl is-active webapp nginx'
```

| Result | Meaning | Action |
|---|---|---|
| `000` | app not listening | host problem → manual reimage |
| `500` | app up but unhealthy | app bug or chaos flag left set → `curl /chaos/fix` |
| `200` | instance is fine | stale alert → check the alert rule's window |

### 3. If the runbook timed out at reimage

Reimage can take longer than 5 minutes on a cold Azure region. Check the job:

```bash
az vmss list-instances -g <rg> -n <vmss> \
  --query "[?instanceId=='<id>'].instanceView.statuses" -o table
```

If it is still `ProvisioningState/updating`, wait. If it is `failed`:

```bash
az vmss reimage -g <rg> -n <vmss> --instance-id <id>
# or, if the instance is unrecoverable:
az vmss delete-instances -g <rg> -n <vmss> --instance-ids <id>
# autoscale replaces it within ~90s
```

### 4. Several instances failing at once — STOP AUTOMATION

```bash
# disable the healing alert rules immediately
az monitor metrics alert update -g <rg> -n <prefix>-alert-instance-unavailable --enabled false
az monitor scheduled-query update -g <rg> -n <prefix>-alert-heartbeat-missing --enabled false
az monitor scheduled-query update -g <rg> -n <prefix>-alert-5xx-sustained --enabled false
```

Then check, in this order:

1. **Is the Application Gateway healthy?** A gateway in `Failed` state makes
   every instance look unhealthy.
   `az network application-gateway show -g <rg> -n <prefix>-appgw --query operationalState`
2. **Is the image broken?** A bad `cloud-init.yaml` or a package repo outage
   makes every *newly reimaged* instance fail. This is the dangerous case:
   healing makes the outage worse. Roll back `app/cloud-init.yaml`, redeploy,
   then reimage instances one at a time.
3. **Is the Automation Account broken?**
   `az automation runbook list -g <rg> -n <prefix>-aa -o table` and check the
   account's identity still has the role assignment (someone may have
   rescoped it).
4. **Is it a platform incident?** Check the Azure status page before
   debugging further.

Only re-enable the alert rules once you can explain *why* they fired.

## Alert: "5xx sustained" (SEV2)

The gateway is serving 500s but instances report healthy. In this
implementation that means the app is returning errors the probe does not
exercise (a real endpoint), or WAF is blocking legitimate traffic.

```kusto
AzureDiagnostics
| where ResourceType == "APPLICATIONGATEWAYS"
| where httpStatus_d >= 500
| summarize Hits=count() by requestUri_s, bin(TimeGenerated, 5m)
| top 20 by Hits desc
```

If the failing URIs are all on one instance, target it:
`az vmss reimage -g <rg> -n <vmss> --instance-id <id>`.

## Alert: "Guest heartbeat missing" (SEV2)

Usually the Azure Monitor agent restarting after a host update. The restart
runbook handles it. If two heartbeats are missed for the same instance in 24h,
investigate the agent logs:

```bash
az vmss run-command invoke -g <rg> -n <vmss> --instance-id <id> \
  --command-id RunShellScript \
  --scripts 'sudo tail -n 100 /var/opt/microsoft/azuremonitoragent/log/mdsd.err'
```

## Post-incident: what to add

Every failed healing attempt should end with one of:

- a **new alert rule** if detection was late,
- a **new runbook branch** if the remediation was wrong for that failure,
- a **chaos scenario** in Azure Chaos Studio so the failure is exercised
  continuously instead of discovered in production.
