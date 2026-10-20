# Cost model — Self-Healing Web App on Azure

Estimates in **INR/month** for `centralindia`, prices as of the time of writing
(verify with the Azure Pricing Calculator; these move).

## dev

| Resource | SKU / config | Qty | Monthly |
|---|---|---|---|
| Application Gateway | WAF_v2, 2 CU fixed (autoscale 2–10) | 1 | ~₹18,500 |
| VMSS instances | Standard_B2s, 2 instances | 2 | ~₹4,200 |
| Managed disks | Premium_LRS 30 GB | 2 | ~₹1,300 |
| Public IP | Standard, static | 1 | ~₹300 |
| Log Analytics | PerGB2018, ~2 GB/mo, 30-day retention | 1 | ~₹500 |
| Automation Account | Basic, 500 min free | 1 | ~₹0 |
| Bandwidth | egress ~10 GB | — | ~₹600 |
| **Total** | | | **~₹25,400** |

## prod

| Resource | SKU / config | Qty | Monthly |
|---|---|---|---|
| Application Gateway | WAF_v2, 3 CU fixed (autoscale 3–20) | 1 | ~₹27,000 |
| VMSS instances | Standard_D2s_v5, 3 instances | 3 | ~₹14,500 |
| Managed disks | Premium_LRS 64 GB | 3 | ~₹4,300 |
| Public IP | Standard | 1 | ~₹300 |
| Log Analytics | PerGB2018, ~15 GB/mo, 90-day retention | 1 | ~₹4,000 |
| Automation Account | Basic | 1 | ~₹0 |
| Bandwidth | egress ~100 GB | — | ~₹4,500 |
| **Total** | | | **~₹54,600** |

## Where the money goes, and what to do about it

**The Application Gateway is ~70% of the bill.** It is also the least
interesting part of this project. Options:

1. **Drop it for Azure Front Door + AKS ingress** — Front Door standard is
   ~₹6,000/mo and gives you global anycast, WAF and health probes. Only worth
   it once you have more than one origin.
2. **Use a Standard Load Balancer** (~₹1,800/mo) if you do not need WAF. You
   lose the built-in probe-based backend pool membership, so you would do
   health-based removal in the app layer — more work, less reliable.
3. **Kill the VMSS entirely.** AKS `Standard_B2s` node pool of 2 is ~₹6,000/mo
   and gives you liveness/readiness probes, PDBs and rolling restarts for free.
   This is what I would actually do in production; see the "what I would do
   differently" section in the README.

**Log Analytics retention is the sneaky cost.** 90 days at 15 GB/mo is fine;
the moment you enable container insights or verbose diagnostic categories it
doubles. Set a daily cap (`dailyQuotaGb`) in non-prod.

**Automation runbook minutes are free** at this volume (500 min/mo included).
The cost of the healing system is effectively zero — which is the point: the
expensive part of self-healing is the *observability*, not the automation.
