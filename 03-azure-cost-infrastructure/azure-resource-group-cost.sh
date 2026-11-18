#!/usr/bin/env bash

set -u

# ============================================================
# Azure Cost Monitor
# ============================================================

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"

START_DATE="${1:-$(date +%Y-%m-01)}"
END_DATE="${2:-$(date -d '+1 day' +%Y-%m-%d)}"

HISTORY_FILE="${HISTORY_FILE:-$HOME/azure-cost-history.csv}"

API_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

echo "============================================================"
echo " AZURE COST REPORT"
echo "============================================================"
echo "Subscription  : $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Period        : $START_DATE -> $END_DATE"
echo "============================================================"
echo

# ------------------------------------------------------------
# Set subscription
# ------------------------------------------------------------

az account set --subscription "$SUBSCRIPTION_ID"

# ------------------------------------------------------------
# Check resources currently existing in Tamra RG
# ------------------------------------------------------------

echo "Checking current Tamra resources..."
echo

RESOURCE_COUNT=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --query "length(@)" \
    --output tsv)

echo "Resources currently in $RESOURCE_GROUP: $RESOURCE_COUNT"
echo

if [ "$RESOURCE_COUNT" -gt 0 ]; then

    az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[].{Name:name,Type:type,Location:location}" \
        --output table

else

    echo "No resources currently found in $RESOURCE_GROUP."

fi

echo
echo "============================================================"
echo " FETCHING COST DATA"
echo "============================================================"
echo

# ------------------------------------------------------------
# Cost query
# ------------------------------------------------------------

BODY=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {
    "from": "${START_DATE}T00:00:00Z",
    "to": "${END_DATE}T00:00:00Z"
  },
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": {
        "name": "PreTaxCost",
        "function": "Sum"
      }
    },
    "grouping": [
      {
        "type": "Dimension",
        "name": "ResourceId"
      },
      {
        "type": "Dimension",
        "name": "ResourceType"
      }
    ],
    "filter": {
      "dimensions": {
        "name": "ResourceGroupName",
        "operator": "In",
        "values": [
          "${RESOURCE_GROUP}"
        ]
      }
    }
  }
}
EOF
)

MAX_RETRIES=6
RETRY=0

while true; do

    echo "Fetching Azure costs..."

    RESPONSE=$(az rest \
        --method post \
        --url "$API_URL" \
        --body "$BODY" \
        --output json 2>&1)

    if echo "$RESPONSE" | grep -q '"rows"'; then
        break
    fi

    if echo "$RESPONSE" | grep -q '429\|Too Many Requests'; then

        RETRY=$((RETRY + 1))

        if [ "$RETRY" -gt "$MAX_RETRIES" ]; then
            echo
            echo "ERROR: Azure Cost Management is still rate-limiting requests."
            echo "Please wait a few minutes and try again."
            exit 1
        fi

        WAIT=$((RETRY * 15))

        echo "Azure returned HTTP 429."
        echo "Retry $RETRY/$MAX_RETRIES in ${WAIT}s..."
        sleep "$WAIT"

    else

        echo
        echo "ERROR:"
        echo "$RESPONSE"
        exit 1

    fi

done

# ------------------------------------------------------------
# Extract total cost
# ------------------------------------------------------------

TOTAL_COST=$(echo "$RESPONSE" | jq -r '
    .properties.rows
    | map(.[0] // 0)
    | add // 0
')

CURRENCY=$(echo "$RESPONSE" | jq -r '
    .properties.rows[0][1] // "USD"
')

echo
echo "============================================================"
echo " TOTAL RESOURCE GROUP COST"
echo "============================================================"
echo
printf "Period       : %s -> %s\n" "$START_DATE" "$END_DATE"
printf "Total Cost   : %.6f %s\n" "$TOTAL_COST" "$CURRENCY"
echo

# ------------------------------------------------------------
# Cost by resource
# ------------------------------------------------------------

echo "============================================================"
echo " COST BY RESOURCE"
echo "============================================================"
echo

echo "$RESPONSE" | jq -r '
    .properties as $p
    | ($p.columns | map(.name)) as $columns

    | ($p.rows
        | sort_by(.[0])
        | reverse
      )[]

    | [
        (.[0] // 0),
        (.[1] // ""),
        (.[2] // "")
      ]
    | @tsv
' | while IFS=$'\t' read -r COST RESOURCE_ID RESOURCE_TYPE; do

    RESOURCE_NAME="$RESOURCE_ID"

    if [ -n "$RESOURCE_ID" ]; then
        RESOURCE_NAME=$(basename "$RESOURCE_ID")
    fi

    printf "%-35s %-55s %12s %s\n" \
        "$RESOURCE_NAME" \
        "$RESOURCE_TYPE" \
        "$COST" \
        "$CURRENCY"

done

echo

# ------------------------------------------------------------
# Save history
# ------------------------------------------------------------

if [ ! -f "$HISTORY_FILE" ]; then
    echo "date,start_date,end_date,resource_group,total_cost,currency" \
        > "$HISTORY_FILE"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S'),$START_DATE,$END_DATE,$RESOURCE_GROUP,$TOTAL_COST,$CURRENCY" \
    >> "$HISTORY_FILE"

echo "============================================================"
echo " HISTORY"
echo "============================================================"
echo
echo "Saved to:"
echo "$HISTORY_FILE"
echo

tail -5 "$HISTORY_FILE"

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
