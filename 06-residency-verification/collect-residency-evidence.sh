#!/usr/bin/env bash
# =============================================================================
# collect-residency-evidence.sh
#
# READ-ONLY Azure data-residency evidence collector.
# It only runs list / show / query commands. It changes NOTHING in Azure.
#
# Usage:
#   ./collect-residency-evidence.sh [subscription-id-or-name]
#   CHECK_AWS=1 AWS_REGIONS="region-a region-b" ./collect-residency-evidence.sh
#
# Needs: az (logged in), jq, column (optional, for pretty tables)
# Output contains live cloud identifiers. Keep it private and out of source control.
# Output: ./cloud-residency-evidence-YYYY-MM-DD/
# =============================================================================
set -uo pipefail

SUB_ARG="${1:-}"
OUT="cloud-residency-evidence-$(date +%F)"
mkdir -p "$OUT"/{00-account,01-inventory,02-data-locations,03-config-evidence,04-compliance-docs,99-logs}
ERR="$OUT/99-logs/errors.log"; : > "$ERR"
FLAGS="$OUT/FLAGS-for-PM.md"
FAILS=0

# ---------- helpers ----------------------------------------------------------
section() { printf '\n=== %s ===\n' "$*"; }

# run a command, save its stdout to a file; on failure save [] and log it
jrun() {
  local out="$1"; shift
  if "$@" > "$out" 2>>"$ERR"; then :; else
    echo "  ! FAILED: $*" | tee -a "$ERR" >&2
    echo '[]' > "$out"; FAILS=$((FAILS+1))
  fi
}

# append each element of a JSON-array command output to an ndjson file
append() { local f="$1"; shift; "$@" </dev/null 2>>"$ERR" | jq -c '.[]' >> "$f" 2>>"$ERR" || true; }
finalize() { jq -s '.' "$1" > "${1%.ndjson}.json" 2>>"$ERR"; rm -f "$1"; }

# print a JSON array of flat objects as an aligned table
tbl() {
  local f="$1"
  jq -e 'length>0' "$f" >/dev/null 2>&1 || { echo "  (none found)"; return; }
  jq -r '(.[0]|keys_unsorted) as $k | $k, (.[]|[.[$k[]]|tostring]) | @tsv' "$f" \
    | { command -v column >/dev/null && column -t -s$'\t' || cat; }
}

# Azure Resource Graph with paging -> JSON array file
graph_json() {
  local q="$1" out="$2" skip=0 page=1000 n tmp; tmp=$(mktemp)
  while :; do
    if ! az graph query -q "$q" --subscriptions "$SUB_ID" --first "$page" --skip "$skip" -o json \
         > "$tmp.page" 2>>"$ERR"; then
      echo "  ! graph query failed (see $ERR)" >&2; FAILS=$((FAILS+1))
      echo '[]' > "$out"; rm -f "$tmp" "$tmp.page"; return 1
    fi
    jq -c '.data[]' "$tmp.page" >> "$tmp"
    n=$(jq '.data|length' "$tmp.page")
    [ "$n" -lt "$page" ] && break
    skip=$((skip+page))
  done
  jq -s '.' "$tmp" > "$out"; rm -f "$tmp" "$tmp.page"
}

flag() { printf -- '- %s\n' "$*" >> "$FLAGS"; echo "  FLAG: $*"; }

# jq helper: true if a region string is UAE North / UAE Central
JQ_UAE='def uae: (. // "") | ascii_downcase | gsub(" ";"") | test("^(uaenorth|uaecentral)$");'

# ---------- preflight --------------------------------------------------------
for bin in az jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin"; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not logged in. Run: az login"; exit 1; }
[ -n "$SUB_ARG" ] && az account set --subscription "$SUB_ARG"

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

section "Target"
echo "Subscription : $SUB_NAME"
echo "Sub ID       : $SUB_ID"
echo "Tenant ID    : $TENANT_ID"
if [ -t 0 ]; then
  read -r -p "Is this the PRODUCTION subscription? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted. Re-run with the right subscription."; exit 1; }
fi

az extension show --name resource-graph >/dev/null 2>&1 \
  || az extension add --name resource-graph --only-show-errors >>"$ERR" 2>&1

echo "# Items to flag to the PM (generated $(date -u +%FT%TZ))" > "$FLAGS"
echo >> "$FLAGS"

# ---------- 00 account -------------------------------------------------------
section "00 Account"
az account show --query "{subscriptionName:name,subscriptionId:id,tenantId:tenantId,tenantDisplayName:tenantDisplayName,state:state,signedInAs:user.name,collectedAtUtc:'$(date -u +%FT%TZ)'}" \
  -o json | tee "$OUT/00-account/subscription-and-tenant.json"

# ---------- Task 1 -----------------------------------------------------------
section "Task 1: inventory"
I="$OUT/01-inventory"

graph_json 'resources | project name, type, resourceGroup, location, subscriptionId, id | order by type asc, id asc' "$I/inventory-all.json"
jq -r '(["name","type","resourceGroup","location","subscriptionId","id"]),
       (.[]|[.name,.type,.resourceGroup,.location,.subscriptionId,.id]) | @csv' \
   "$I/inventory-all.json" > "$I/inventory-all.csv"
echo "Total resources: $(jq length "$I/inventory-all.json")"

graph_json 'resources | where location !in ("uaenorth", "uaecentral") | project name, type, resourceGroup, location, id | order by type asc, id asc' "$I/inventory-non-uae.json"
jq -r '(["name","type","resourceGroup","location","id","reason"]),
       (.[]|[.name,.type,.resourceGroup,.location,.id,
             (if (.location|ascii_downcase)=="global"
              then "TODO (global, usually expected): what does it do? does it cache/store app data?"
              else "TODO: NOT global and NOT UAE - explain and tell the PM" end)]) | @csv' \
   "$I/inventory-non-uae.json" > "$I/inventory-non-uae.csv"

NON_UAE=$(jq length "$I/inventory-non-uae.json")
NON_UAE_REAL=$(jq '[.[]|select((.location|ascii_downcase)!="global")]|length' "$I/inventory-non-uae.json")
echo "Outside UAE: $NON_UAE  (of which NOT 'global': $NON_UAE_REAL)"
tbl "$I/inventory-non-uae.json"
[ "$NON_UAE_REAL" -gt 0 ] && flag "$NON_UAE_REAL resource(s) are outside UAE and not 'global' - see 01-inventory/inventory-non-uae.csv"
[ "$NON_UAE" -gt "$NON_UAE_REAL" ] && flag "$((NON_UAE-NON_UAE_REAL)) 'global' resource(s) (DNS/Front Door/CDN/etc.) - each needs a one-line reason (reason column)"

jrun "$I/resource-groups.json" az group list --query "[].{name:name,location:location}" -o json

# ---------- Task 2 -----------------------------------------------------------
section "Task 2: data locations"
D="$OUT/02-data-locations"

# --- Storage
echo "-- Storage accounts"
jrun "$D/storage-accounts.json" az storage account list \
  --query "[].{name:name,resourceGroup:resourceGroup,location:location,primary:primaryLocation,secondary:secondaryLocation,sku:sku.name,kind:kind,secondaryStatus:statusOfSecondary}" -o json
tbl "$D/storage-accounts.json"
jq -r "$JQ_UAE"'.[]|select((.primary|uae|not) or (.secondary!=null and (.secondary|uae|not)))|"Storage \(.name): primary=\(.primary) secondary=\(.secondary)"' \
  "$D/storage-accounts.json" | while read -r l; do flag "$l (outside UAE)"; done
jq -r '.[]|select((.sku|test("GRS|GZRS";"i")) and .secondary==null)|"Storage \(.name): SKU \(.sku) but no secondary region reported - verify in portal"' \
  "$D/storage-accounts.json" | while read -r l; do flag "$l"; done

# --- Azure SQL
echo "-- Azure SQL"
jrun "$D/sql-servers.json" az sql server list --query "[].{name:name,resourceGroup:resourceGroup,location:location}" -o json
SQLDB="$D/sql-databases.ndjson"; SQLREP="$D/sql-replica-links.ndjson"; SQLFG="$D/sql-failover-groups.ndjson"
: > "$SQLDB"; : > "$SQLREP"; : > "$SQLFG"
while IFS=$'\t' read -r rg srv; do
  [ -z "${srv:-}" ] && continue
  append "$SQLDB" az sql db list -g "$rg" -s "$srv" -o json \
    --query "[?name!='master'].{server:'$srv',resourceGroup:'$rg',name:name,location:location,sku:sku.name,zoneRedundant:zoneRedundant,requestedBackupRedundancy:requestedBackupStorageRedundancy,currentBackupRedundancy:currentBackupStorageRedundancy}"
  append "$SQLFG" az sql failover-group list -g "$rg" -s "$srv" -o json \
    --query "[].{server:'$srv',name:name,role:replicationRole,policy:readWriteEndpoint.failoverPolicy,partnerServers:partnerServers[].id}"
  for db in $(az sql db list -g "$rg" -s "$srv" --query "[?name!='master'].name" -o tsv </dev/null 2>>"$ERR"); do
    append "$SQLREP" az sql db replica list-links -g "$rg" -s "$srv" -n "$db" -o json \
      --query "[].{database:'$db',server:'$srv',partnerServer:partnerServer,partnerLocation:partnerLocation,role:role,partnerRole:partnerRole,state:replicationState}"
  done
done < <(jq -r '.[]|[.resourceGroup,.name]|@tsv' "$D/sql-servers.json")
finalize "$SQLDB"; finalize "$SQLREP"; finalize "$SQLFG"
tbl "$D/sql-databases.json"; tbl "$D/sql-replica-links.json"
jq -r "$JQ_UAE"'.[]|select(.partnerLocation|uae|not)|"SQL replica \(.server)/\(.database) -> \(.partnerLocation)"' \
  "$D/sql-replica-links.json" | while read -r l; do flag "$l (outside UAE)"; done
jq -r '.[]|select((.currentBackupRedundancy//"")|test("Geo";"i"))|"SQL \(.server)/\(.name): backups are \(.currentBackupRedundancy) (geo copy goes to the paired region - confirm it is UAE Central; geo-restore is possible)"' \
  "$D/sql-databases.json" | while read -r l; do flag "$l"; done

# --- PostgreSQL / MySQL flexible servers
for eng in postgres mysql; do
  echo "-- $eng flexible servers"
  F="$D/${eng}-flexible-servers.json"
  jrun "$F" az "$eng" flexible-server list -o json \
    --query "[].{name:name,resourceGroup:resourceGroup,location:location,version:version,geoRedundantBackup:backup.geoRedundantBackup,backupRetentionDays:backup.backupRetentionDays,haMode:highAvailability.mode,haStandbyZone:highAvailability.standbyAvailabilityZone,replicationRole:replicationRole}"
  tbl "$F"
  R="$D/${eng}-replicas.ndjson"; : > "$R"
  while IFS=$'\t' read -r rg srv; do
    [ -z "${srv:-}" ] && continue
    append "$R" az "$eng" flexible-server replica list -g "$rg" -n "$srv" -o json \
      --query "[].{primaryServer:'$srv',replica:name,location:location}"
  done < <(jq -r '.[]|[.resourceGroup,.name]|@tsv' "$F")
  finalize "$R"
  jq -r --arg e "$eng" "$JQ_UAE"'.[]|select(.location|uae|not)|"\($e) \(.name): server in \(.location)"' "$F" \
    | while read -r l; do flag "$l (outside UAE)"; done
  jq -r "$JQ_UAE"'.[]|select(.location|uae|not)|"'"$eng"' replica \(.replica) of \(.primaryServer): \(.location)"' "$D/${eng}-replicas.json" \
    | while read -r l; do flag "$l (outside UAE)"; done
  jq -r '.[]|select((.geoRedundantBackup//"")|test("Enabled";"i"))|"'"$eng"' \(.name): geo-redundant backup ENABLED (copy in paired region - confirm it is UAE Central)"' "$F" \
    | while read -r l; do flag "$l"; done
done

# --- Cosmos DB
echo "-- Cosmos DB"
jrun "$D/cosmosdb.json" az cosmosdb list -o json \
  --query "[].{name:name,resourceGroup:resourceGroup,location:location,writeRegions:writeLocations[].locationName,readRegions:readLocations[].locationName,multiWrite:enableMultipleWriteLocations,autoFailover:enableAutomaticFailover,backupType:backupPolicy.type,backupRedundancy:backupPolicy.periodicModeProperties.backupStorageRedundancy}"
tbl "$D/cosmosdb.json"
jq -r "$JQ_UAE"'.[]|select(([.writeRegions[]?,.readRegions[]?]|map(uae|not)|any))|"Cosmos \(.name): regions \(([.writeRegions[]?,.readRegions[]?]|unique|join(", ")))"' \
  "$D/cosmosdb.json" | while read -r l; do flag "$l (some region outside UAE)"; done

# --- Recovery Services vaults (+ Cross Region Restore)
echo "-- Recovery Services vaults"
jrun "$D/recovery-vaults-list.json" az backup vault list --query "[].{name:name,resourceGroup:resourceGroup,location:location}" -o json
V="$D/recovery-vaults.ndjson"; : > "$V"
while IFS=$'\t' read -r rg name loc; do
  [ -z "${name:-}" ] && continue
  az backup vault backup-properties show -n "$name" -g "$rg" -o json </dev/null 2>>"$ERR" \
    | jq -c --arg v "$name" --arg rg "$rg" --arg loc "$loc" 'if type=="array" then .[0] else . end | {vault:$v,resourceGroup:$rg,location:$loc} + .' >> "$V" || true
done < <(jq -r '.[]|[.resourceGroup,.name,.location]|@tsv' "$D/recovery-vaults-list.json")
finalize "$V"
cat "$D/recovery-vaults.json" | jq -c '.[]'
jq -r '.[]|select((.crossRegionRestoreFlag//false)==true)|"Vault \(.vault): Cross Region Restore ENABLED (restores can target the paired region - confirm UAE Central)"' \
  "$D/recovery-vaults.json" | while read -r l; do flag "$l"; done

# --- Backup (Data Protection) vaults, Communication Services, App Insights via Resource Graph
echo "-- Data Protection vaults / Communication Services / App Insights"
graph_json 'resources | where type =~ "microsoft.dataprotection/backupvaults" | project name, resourceGroup, location, storageSettings=properties.storageSettings' "$D/dataprotection-vaults.json"
graph_json 'resources | where type =~ "microsoft.communication/communicationservices" | project name, resourceGroup, location, dataLocation=properties.dataLocation' "$D/communication-services.json"
jq -r "$JQ_UAE"'.[]|select(.dataLocation|uae|not)|"Communication Services \(.name): dataLocation=\(.dataLocation)"' "$D/communication-services.json" \
  | while read -r l; do flag "$l (data location is NOT UAE)"; done

# --- Container Registry
echo "-- Container Registry"
jrun "$D/acr.json" az acr list --query "[].{name:name,resourceGroup:resourceGroup,location:location,sku:sku.name}" -o json
R="$D/acr-replications.ndjson"; : > "$R"
while IFS=$'\t' read -r rg name; do
  [ -z "${name:-}" ] && continue
  append "$R" az acr replication list -r "$name" -g "$rg" -o json --query "[].{registry:'$name',replica:name,location:location}"
done < <(jq -r '.[]|[.resourceGroup,.name]|@tsv' "$D/acr.json")
finalize "$R"
tbl "$D/acr.json"; tbl "$D/acr-replications.json"
jq -r "$JQ_UAE"'.[]|select(.location|uae|not)|"ACR \(.registry) geo-replica in \(.location)"' "$D/acr-replications.json" \
  | while read -r l; do flag "$l (outside UAE)"; done

# --- Key Vault, Redis
echo "-- Key Vault / Redis"
jrun "$D/keyvaults.json" az keyvault list --query "[].{name:name,resourceGroup:resourceGroup,location:location}" -o json
jrun "$D/redis.json" az redis list --query "[].{name:name,resourceGroup:resourceGroup,location:location,sku:sku.name}" -o json
tbl "$D/keyvaults.json"; tbl "$D/redis.json"

# --- Compute / monitoring locations (for Task 3 screenshots list)
echo "-- Compute & monitoring"
graph_json 'resources | where type in~ ("microsoft.web/sites","microsoft.web/serverfarms","microsoft.app/containerapps","microsoft.app/managedenvironments","microsoft.containerservice/managedclusters","microsoft.compute/virtualmachines","microsoft.operationalinsights/workspaces","microsoft.insights/components","microsoft.cognitiveservices/accounts","microsoft.network/frontdoors","microsoft.cdn/profiles","microsoft.network/dnszones","microsoft.network/trafficmanagerprofiles") | project name, type, resourceGroup, location | order by type asc' "$D/compute-and-monitoring.json"
tbl "$D/compute-and-monitoring.json"

# --- Pre-filled Task 2 table (facts from CLI only; fill the blanks by hand)
T="$D/TASK2-data-locations-table.csv"
{
  echo '"Resource name","Type","Primary region","Secondary / replica region","Backup location & redundancy","DR copy region","Holds personal or health data?","Evidence file"'
  jq -r '.[]|[.name,"Storage account",.primary,(.secondary//""),("SKU "+.sku),(.secondary//""),"TODO","TODO"]|@csv' "$D/storage-accounts.json"
  jq -r '.[]|[(.server+"/"+.name),"Azure SQL DB",.location,"","backup: "+(.currentBackupRedundancy//"?"),"","TODO","TODO"]|@csv' "$D/sql-databases.json"
  for eng in postgres mysql; do
    jq -r --arg e "$eng" '.[]|[.name,($e+" flexible server"),.location,"see '"$eng"'-replicas.json","geo-redundant backup: "+(.geoRedundantBackup//"?"),"","TODO","TODO"]|@csv' "$D/${eng}-flexible-servers.json"
  done
  jq -r '.[]|[.name,"Cosmos DB",.location,((.readRegions//[])|join("; ")),("backup: "+(.backupType//"?")+" / "+(.backupRedundancy//"?")),"","TODO","TODO"]|@csv' "$D/cosmosdb.json"
  jq -r '.[]|[.vault,"Recovery Services vault",.location,"","storage: "+(.storageModelType//.storageType//"?")+", CRR: "+((.crossRegionRestoreFlag//false)|tostring),"","TODO","TODO"]|@csv' "$D/recovery-vaults.json"
  jq -r '.[]|[.name,"Container Registry",.location,"see acr-replications.json","","","TODO","TODO"]|@csv' "$D/acr.json"
  jq -r '.[]|[.name,"Key Vault",.location,"","","","TODO","TODO"]|@csv' "$D/keyvaults.json"
  jq -r '.[]|[.name,"Redis",.location,"","","","TODO","TODO"]|@csv' "$D/redis.json"
} > "$T"
echo "Prefilled table: $T"

# ---------- Task 3: Azure Policy ---------------------------------------------
section "Task 3: Azure Policy - Allowed locations"
P="$OUT/03-config-evidence"
jrun "$P/policy-assignments-all.json" az policy assignment list --disable-scope-strict-match \
  --scope "/subscriptions/$SUB_ID" \
  --query "[].{name:name,displayName:displayName,scope:scope,enforcementMode:enforcementMode,policyDefinitionId:policyDefinitionId,parameters:parameters}" -o json
jq '[.[]|select((.displayName//"")|test("allowed locations";"i"))]' \
  "$P/policy-assignments-all.json" > "$P/policy-allowed-locations.json"
if jq -e 'length>0' "$P/policy-allowed-locations.json" >/dev/null; then
  jq '.' "$P/policy-allowed-locations.json"
  while read -r an; do
    az policy state summarize --policy-assignment "$an" -o json > "$P/policy-compliance-$an.json" 2>>"$ERR" \
      || echo "  (could not summarize '$an' - check in portal; may be assigned at management-group scope)"
  done < <(jq -r '.[].name' "$P/policy-allowed-locations.json")
  jq -r '.[]|"Policy \(.name): enforcement=\(.enforcementMode) allowed=\(.parameters.listOfAllowedLocations.value // "?"|tostring)"' \
    "$P/policy-allowed-locations.json" | while read -r l; do echo "  $l"; done
  jq -r '.[]|select(.enforcementMode=="DoNotEnforce")|"Policy \(.name) is DoNotEnforce (audit only, not blocking)"' \
    "$P/policy-allowed-locations.json" | while read -r l; do flag "$l"; done
else
  echo "  No 'Allowed locations' assignment found."
  flag "NO 'Allowed locations' Azure Policy found on the subscription. Tell the PM BEFORE creating one (it is the strongest evidence that the restriction is enforced)."
fi

# ---------- Optional: leftovers on AWS (listing only) ------------------------
if [ "${CHECK_AWS:-0}" = "1" ] && command -v aws >/dev/null 2>&1; then
  section "Optional: AWS leftovers (list only, nothing is deleted)"
  A="$OUT/02-data-locations/aws"; mkdir -p "$A"
  aws sts get-caller-identity --query "{account:Account,arn:Arn}" -o json > "$A/identity.json" 2>>"$ERR"
  aws s3api list-buckets --query "Buckets[].Name" -o json > "$A/s3-buckets.json" 2>>"$ERR"
  for r in ${AWS_REGIONS:-$(aws configure get region)}; do
    aws rds describe-db-instances --region "$r" --query "DBInstances[].{id:DBInstanceIdentifier,engine:Engine,az:AvailabilityZone}" -o json > "$A/rds-instances-$r.json" 2>>"$ERR"
    aws rds describe-db-snapshots --region "$r" --query "DBSnapshots[].{id:DBSnapshotIdentifier,instance:DBInstanceIdentifier,type:SnapshotType,created:SnapshotCreateTime}" -o json > "$A/rds-snapshots-$r.json" 2>>"$ERR"
    aws elasticbeanstalk describe-environments --region "$r" --query "Environments[].{name:EnvironmentName,status:Status}" -o json > "$A/eb-environments-$r.json" 2>>"$ERR"
  done
  for f in "$A"/s3-buckets.json "$A"/rds-instances-*.json "$A"/rds-snapshots-*.json; do
    [ -f "$f" ] && jq -e 'length>0' "$f" >/dev/null 2>&1 && flag "AWS leftovers present in $(basename "$f") - review data location; do not delete"
  done
else
  echo
  echo "(AWS check skipped. Run with CHECK_AWS=1 AWS_REGIONS=\"region1 region2\" to list leftovers.)"
fi

# ---------- Manual items checklist -------------------------------------------
cat > "$OUT/MANUAL-TODO.md" <<EOF
# Cannot be done from the CLI - do by hand

- [ ] Migration completion date (date production traffic moved to Azure UAE)
- [ ] Task 3 screenshots (URL bar/resource name + date visible), named <task>-<resource>-<setting>.png:
      each DB (Overview + backup/replication), each storage account (Overview + Data management > Redundancy),
      each backup vault (Properties > Backup configuration), App Service / compute Overview,
      Log Analytics + Application Insights Overview, Azure Policy assignment + compliance (if exists)
- [ ] Task 4: from servicetrust.microsoft.com -> put in 04-compliance-docs/
      ISO 27001 cert, latest SOC 2 Type 2, DPA, DESC CSP certification (if available)
- [ ] Fill TODO columns in 02-data-locations/TASK2-data-locations-table.csv
      (health/personal data? evidence file) and the 'reason' column in 01-inventory/inventory-non-uae.csv
- [ ] Other copies: dumps/exports on developer machines, non-Azure buckets, CI artifacts
- [ ] Read FLAGS-for-PM.md and send to the PM. Do NOT change any setting to improve the result.
EOF

# ---------- secret scan -------------------------------------------------------
section "Secret scan (should print nothing)"
grep -rEIl -i 'AccountKey=|SharedAccessKey=|DefaultEndpointsProtocol=|Endpoint=sb://|-----BEGIN|sig=[A-Za-z0-9%]{20,}|eyJ[A-Za-z0-9_-]{20,}\.|"password"|"primaryKey"' "$OUT" 2>/dev/null \
  | sed 's/^/  POSSIBLE SECRET in: /'

# ---------- summary ------------------------------------------------------------
section "Done"
echo "Folder       : $OUT"
echo "Failed calls : $FAILS  (details in $ERR - usually missing permissions or a resource type you do not use)"
echo "Flags for PM : $(grep -c '^- ' "$FLAGS") (see $FLAGS)"
echo "Manual items : $OUT/MANUAL-TODO.md"
