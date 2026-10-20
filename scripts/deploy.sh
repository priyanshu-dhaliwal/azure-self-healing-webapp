#!/usr/bin/env bash
# Deploy the self-healing web app. Always run what-if first.
#
#   ./scripts/deploy.sh dev what-if
#   ./scripts/deploy.sh dev
set -euo pipefail

ENV="${1:-dev}"
MODE="${2:-deploy}"
LOCATION="${LOCATION:-centralindia}"
PARAMS="infra/params/${ENV}.bicepparam"

if [ ! -f "$PARAMS" ]; then
  echo "No parameter file: $PARAMS" >&2
  exit 1
fi

echo "==> Bicep build (syntax + type check)"
az bicep build --file infra/main.bicep --stdout > /dev/null

echo "==> Subscription: $(az account show --query name -o tsv) ($(az account show --query id -o tsv))"

if [ "$MODE" = "what-if" ]; then
  echo "==> What-if for $ENV"
  az deployment sub what-if \
    --name "shw-${ENV}-$(date +%Y%m%d%H%M%S)" \
    --location "$LOCATION" \
    --template-file infra/main.bicep \
    --parameters "$PARAMS" \
    --result-format FullResourcePayloads
else
  echo "==> Deploying $ENV"
  az deployment sub create \
    --name "shw-${ENV}-$(date +%Y%m%d%H%M%S)" \
    --location "$LOCATION" \
    --template-file infra/main.bicep \
    --parameters "$PARAMS" \
    --output table
fi
