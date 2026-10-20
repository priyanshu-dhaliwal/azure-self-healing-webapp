#!/usr/bin/env bash
# Fault injection — the whole point of this repo. Break something on purpose
# and watch the platform heal it.
#
#   ./scripts/inject-fault.sh kill      # SIGKILL the app process on a random instance
#   ./scripts/inject-fault.sh break     # make /health return 500 on a random instance
#   ./scripts/inject-fault.sh hang      # make the app hang for 120s on a random instance
#   ./scripts/inject-fault.sh zone      # stop all instances in one zone (bigger blast radius)
#   ./scripts/inject-fault.sh list      # show instance ids and health state
set -euo pipefail

MODE="${1:-list}"
RG="${RG:-rg-dev-selfhealing-dev01}"
VMSS="${VMSS:-dev-shw-dev01-vmss}"

instances() {
  az vmss list-instances -g "$RG" -n "$VMSS" \
    --query "[].{id:instanceId, zone:zones[0], state:provisioningState}" -o tsv
}

case "$MODE" in
  list)
    printf "%-12s %-6s %s\n" INSTANCE ZONE STATE
    instances | while IFS=$'\t' read -r id zone state; do
      printf "%-12s %-6s %s\n" "$id" "$zone" "$state"
    done
    ;;

  kill)
    ID=$(instances | shuf -n1 | cut -f1)
    echo "==> SIGKILL the app on instance $ID (nginx stays up, /health goes 500)"
    az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
      --command-id RunShellScript \
      --scripts 'systemctl stop webapp; sleep 1; echo stopped; systemctl is-active webapp || true' \
      --query "value[0].message" -o tsv
    echo "==> Watch: az monitor log-analytics query -w <law-id> --analytics-query 'HealingAudit_CL | take 10'"
    ;;

  break)
    ID=$(instances | shuf -n1 | cut -f1)
    echo "==> Force /health to 500 on instance $ID (host and agent stay healthy)"
    az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
      --command-id RunShellScript \
      --scripts 'curl -s http://127.0.0.1:8080/chaos/break && echo' \
      --query "value[0].message" -o tsv
    ;;

  hang)
    ID=$(instances | shuf -n1 | cut -f1)
    echo "==> Make the app hang for 120s on instance $ID (probe timeout path)"
    az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
      --command-id RunShellScript \
      --scripts 'curl -s -m 3 http://127.0.0.1:8080/chaos/hang || true; echo' \
      --query "value[0].message" -o tsv
    ;;

  zone)
    ZONE=$(instances | cut -f2 | sort -u | shuf -n1)
    echo "==> Deallocating every instance in zone $ZONE (capacity event, not a healing event)"
    for ID in $(instances | awk -v z="$ZONE" '$2==z{print $1}'); do
      az vmss deallocate -g "$RG" -n "$VMSS" --instance-ids "$ID" --no-wait
      echo "   deallocated $ID"
    done
    echo "==> Autoscale should add instances; check:"
    echo "    az monitor autoscale show -g $RG -n ${VMSS}-autoscale --query 'profiles[0].capacity'"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
