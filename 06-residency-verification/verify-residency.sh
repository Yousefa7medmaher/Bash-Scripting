#!/usr/bin/env bash
# Read-only Azure location inventory. Output omits subscription, resource, and
# account names so reports can be reviewed without exposing identifiers.
set -Eeuo pipefail

ALLOWED_LOCATIONS="${ALLOWED_LOCATIONS:?Set ALLOWED_LOCATIONS (space-separated Azure locations)}"
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-}"
OUT="${OUTPUT_DIR:-residency-report-$(date -u +%Y%m%dT%H%M%SZ)}"

while (($#)); do
  case "$1" in
    --help|-h)
      printf 'Usage: ALLOWED_LOCATIONS="region-a region-b" [AZURE_SUBSCRIPTION_ID=id] %s\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for cmd in az jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not logged in. Run az login first." >&2; exit 1; }
[[ -n "$SUBSCRIPTION" ]] || SUBSCRIPTION="$(az account show --query id -o tsv)"

mkdir -p "$OUT"
INVENTORY="$OUT/location-inventory.json"
SUMMARY="$OUT/location-summary.tsv"
REPORT="$OUT/report.txt"

az resource list --subscription "$SUBSCRIPTION" \
  --query '[].{location:location,type:type}' -o json > "$INVENTORY"

jq -r --arg allowed "$ALLOWED_LOCATIONS" '
  ($allowed | split(" ") | map(ascii_downcase)) as $locations
  | (["location", "resource_type", "count", "outside_allowed"] | @tsv),
    ([.[] | {location:(.location // "unknown"), type:(.type // "unknown")}]
      | group_by([.location, .type])[]
      | .[0] as $entry
      | [$entry.location, $entry.type, length,
         (if ($entry.location | ascii_downcase) == "global"
             or ($locations | index($entry.location | ascii_downcase))
          then "no" else "yes" end)]
      | @tsv)
' "$INVENTORY" > "$SUMMARY"

{
  echo "Azure location inventory"
  echo "Allowed locations: $(printf '%s' "$ALLOWED_LOCATIONS" | tr ' ' ',')"
  echo "Resource count: $(jq 'length' "$INVENTORY")"
  echo "Resources outside the allowlist (global resources excluded):"
  awk -F '\t' 'NR > 1 && $4 == "yes" { total += $3 } END { print total + 0 }' "$SUMMARY"
  echo
  echo "Summary is grouped by location and resource type; identifiers are omitted."
  cat "$SUMMARY"
} > "$REPORT"

cat "$REPORT"
echo
echo "Reports saved under: $OUT (do not publish raw cloud evidence without review)."
