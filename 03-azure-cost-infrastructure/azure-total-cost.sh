#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID}"
API_VERSION="2025-03-01"
OUTPUT_DIR="azure-cost-report-$(date +%Y%m%d-%H%M%S)"

# Change to TheLastMonth for the previous calendar month.
TIMEFRAME="MonthToDate"

mkdir -p "$OUTPUT_DIR"

echo "========================================"
echo " Azure Cost Report"
echo " Subscription: $SUBSCRIPTION_ID"
echo " Period: $TIMEFRAME"
echo "========================================"

# Verify active subscription
az account set --subscription "$SUBSCRIPTION_ID"

query_cost() {
  local output_file="$1"
  local group_by="${2:-}"

  local grouping_json=""
  if [[ -n "$group_by" ]]; then
    grouping_json=',"grouping":[{"type":"Dimension","name":"'"$group_by"'"}]'
  fi

  local body
  body=$(printf \
    '{"type":"Usage","timeframe":"%s","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}%s}}' \
    "$TIMEFRAME" "$grouping_json")

  az rest \
    --method post \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/query?api-version=${API_VERSION}" \
    --body "$body" \
    --output json > "$output_file"
}

echo
echo "[1/3] Querying total subscription cost..."
query_cost "$OUTPUT_DIR/total.json"

echo "[2/3] Querying cost by Resource Group..."
query_cost "$OUTPUT_DIR/by-resource-group.json" "ResourceGroup"

echo "[3/3] Querying cost by Resource..."
query_cost "$OUTPUT_DIR/by-resource.json" "ResourceId"

# Convert API response columns/rows to CSV using Python 3.
python3 - "$OUTPUT_DIR" <<'PY'
import csv
import json
import os
import sys

folder = sys.argv[1]

def export_json_to_csv(source, destination):
    with open(os.path.join(folder, source), encoding="utf-8") as f:
        result = json.load(f)

    props = result.get("properties", {})
    columns = [c["name"] for c in props.get("columns", [])]
    rows = props.get("rows", [])

    with open(os.path.join(folder, destination), "w",
              newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow(columns)
        writer.writerows(rows)

    return columns, rows

columns, rows = export_json_to_csv("total.json", "total.csv")
print("\n========== SUBSCRIPTION TOTAL ==========")
if rows:
    print("Columns:", ", ".join(columns))
    for row in rows:
        print(" | ".join(map(str, row)))
else:
    print("No cost rows returned for this period.")

for source, destination, title in [
    ("by-resource-group.json", "by-resource-group.csv",
     "COST BY RESOURCE GROUP"),
    ("by-resource.json", "by-resource.csv",
     "COST BY RESOURCE"),
]:
    columns, rows = export_json_to_csv(source, destination)
    print(f"\n========== {title} ==========")
    if not rows:
        print("No cost rows returned.")
        continue

    print(" | ".join(columns))
    for row in rows:
        print(" | ".join(map(str, row)))

print(f"\nCSV reports saved in: {folder}/")
PY

echo
echo "Done. Reports:"
echo "  $OUTPUT_DIR/total.csv"
echo "  $OUTPUT_DIR/by-resource-group.csv"
echo "  $OUTPUT_DIR/by-resource.csv"
