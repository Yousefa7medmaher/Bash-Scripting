#!/usr/bin/env bash
# =============================================================================
# Refresh a non-production database using an optional masking stage.
#
# Refreshes the TESTING database from the PRODUCTION database (UAE North), so the
# developers can try changes on realistic data before applying them to production.
#
# Source databases may hold sensitive data, and the testing server may be in
# West US 2. Raw production data must not leave the UAE. So the script works in stages:
#
#   production (UAE)  --read only dump-->  scratch DB (UAE)  --MASK_SQL-->  masked dump  --> testing DB
#
#  - If the destination server is OUTSIDE the UAE, a masking script (MASK_SQL) and a
#    check script (MASK_CHECK_SQL) are mandatory. The copy is refused if the check
#    does not return 0.
#  - If the destination server is inside the UAE, masking is optional.
#  - It only runs on an Azure VM in UAE North / UAE Central (for example the jumpbox).
#  - Production is only READ. Dumps are temporary files and are deleted at the end.
#
# Usage:
#   ./refresh-test-database.sh --discover
#   SRC_HOST=... DST_HOST=... SCRATCH_USER=... MASK_SQL=mask.sql MASK_CHECK_SQL=check.sql ./refresh-test-database.sh
#
# Options: -y (skip the "type the database name" question)  --skip-compare  --discover
# Settings (environment, defaults in brackets):
#   SRC_HOST SRC_DB SRC_USER SRC_RG
#   DST_HOST DST_DB DST_USER DST_RG
#   SCRATCH_HOST [= SRC_HOST] SCRATCH_DB SCRATCH_USER [= SRC_USER] SCRATCH_RG [= SRC_RG]
#   KEY_VAULT_NAME (when using secret names) SRC_PASSWORD_SECRET
#   SRC_PASSWORD / DST_PASSWORD / SCRATCH_PASSWORD (otherwise Key Vault or a prompt)
#   MASK_SQL / MASK_CHECK_SQL (file paths)   WORK_DIR [/var/tmp/db-copy]
#   IMDS_LOCATION_URL (Azure VM metadata location endpoint; required)
# =============================================================================
set -Eeuo pipefail
umask 077

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- settings ----------------------------------------------------------
SRC_HOST="${SRC_HOST:?Set SRC_HOST}"
SRC_PORT="${SRC_PORT:-3306}"
SRC_DB="${SRC_DB:?Set SRC_DB}"
SRC_USER="${SRC_USER:?Set SRC_USER}"
SRC_RG="${SRC_RG:?Set SRC_RG}"
SRC_PASSWORD="${SRC_PASSWORD:-}"
SRC_PASSWORD_SECRET="${SRC_PASSWORD_SECRET:-mysql-app-password}"

DST_HOST="${DST_HOST:?Set DST_HOST}"
DST_PORT="${DST_PORT:-3306}"
DST_DB="${DST_DB:?Set DST_DB}"
DST_USER="${DST_USER:?Set DST_USER}"
DST_RG="${DST_RG:?Set DST_RG}"
DST_PASSWORD="${DST_PASSWORD:-}"
DST_PASSWORD_SECRET="${DST_PASSWORD_SECRET:-}"

SCRATCH_HOST="${SCRATCH_HOST:-$SRC_HOST}"
SCRATCH_PORT="${SCRATCH_PORT:-3306}"
SCRATCH_DB="${SCRATCH_DB:-masked_verify}"
SCRATCH_USER="${SCRATCH_USER:-}"
SCRATCH_RG="${SCRATCH_RG:-$SRC_RG}"
SCRATCH_PASSWORD="${SCRATCH_PASSWORD:-}"
SCRATCH_PASSWORD_SECRET="${SCRATCH_PASSWORD_SECRET:-}"

KV_NAME="${KEY_VAULT_NAME:-}"
SRC_PASSWORD_SECRET="${SRC_PASSWORD_SECRET:-}"
MASK_SQL="${MASK_SQL:-}"
MASK_CHECK_SQL="${MASK_CHECK_SQL:-}"
WORK_DIR="${WORK_DIR:-/var/tmp/db-copy}"
IMDS_LOCATION_URL="${IMDS_LOCATION_URL:-}"

MODE=copy; ASSUME_YES=0; COMPARE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --discover) MODE=discover ;;
    -y|--yes) ASSUME_YES=1 ;;
    --skip-compare) COMPARE=0 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# ---------- helpers -----------------------------------------------------------
norm() { tr 'A-Z' 'a-z' | tr -d ' '; }

RUN_DIR=""; SCRATCH_CREATED=0
cleanup() {
  local rc=$?
  if [ "$SCRATCH_CREATED" = 1 ] && [ -f "${RUN_DIR:-/nonexistent}/scr.cnf" ]; then
    mysql --defaults-extra-file="$RUN_DIR/scr.cnf" -e "DROP DATABASE IF EXISTS \`$SCRATCH_DB\`" >/dev/null 2>&1 \
      && log "Scratch database $SCRATCH_DB dropped." \
      || log "WARNING: could not drop $SCRATCH_DB on $SCRATCH_HOST. Drop it by hand: it holds UNMASKED production data."
  fi
  [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] && rm -rf "$RUN_DIR"
  exit $rc
}
trap cleanup EXIT

confirm() { # message word always
  if [ "$ASSUME_YES" = 1 ] && [ "${3:-0}" != 1 ]; then return 0; fi
  [ -t 0 ] || die "A terminal is needed for the confirmation question."
  local a; read -r -p "$1 Type '$2' to continue: " a
  [ "$a" = "$2" ] || die "Not confirmed."
}

check_machine_region() {
  local r
  [ -n "$IMDS_LOCATION_URL" ] || die "Set IMDS_LOCATION_URL to the Azure VM metadata location endpoint."
  r=$(curl -fsS -m 3 -H 'Metadata:true' "$IMDS_LOCATION_URL" 2>/dev/null | norm) || r=""
  [ -n "$r" ] || die "Could not verify this machine's Azure region. Production data must not be copied to a laptop or a machine outside the UAE."
  case "$r" in
    uaenorth|uaecentral) log "Machine region: $r" ;;
    *) die "This VM is in '$r', not in the UAE. Refusing to continue." ;;
  esac
}

server_region() { # host resource-group
  command -v az >/dev/null 2>&1 || die "az CLI not found (needed to read the server region)."
  local r
  r=$(az mysql flexible-server show -g "$2" -n "${1%%.*}" --query location -o tsv 2>/dev/null | norm) || r=""
  [ -n "$r" ] || die "Could not read the region of $1 (az login? resource group $2?)."
  printf '%s' "$r"
}
is_uae() { case "$1" in uaenorth|uaecentral) return 0 ;; *) return 1 ;; esac; }

get_password() { # value secret-name label
  local val="$1"
  if [ -z "$val" ] && [ -n "$2" ] && command -v az >/dev/null 2>&1; then
    val=$(az keyvault secret show --vault-name "$KV_NAME" --name "$2" --query value -o tsv 2>/dev/null || true)
  fi
  if [ -z "$val" ]; then
    [ -t 0 ] || die "No password for the $3 user (set ${3}_PASSWORD or a Key Vault secret name)."
    read -r -s -p "Password for the $3 user: " val; echo >&2
  fi
  printf '%s' "$val"
}

mk_cnf() { # file host port user password
  local esc
  esc=$(printf '%s' "$5" | sed 's/\\/\\\\/g; s/"/\\"/g')
  { echo "[client]"; echo "host=$2"; echo "port=$3"; echo "user=$4"
    echo "password=\"$esc\""; echo "ssl-mode=REQUIRED"; } > "$1"
  chmod 600 "$1"
}

dump_db() { # cnf db outfile
  mysqldump --defaults-extra-file="$1" \
    --single-transaction --quick --routines --triggers --events \
    --set-gtid-purged=OFF --no-tablespaces --default-character-set=utf8mb4 "$2" \
    | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' \
    | gzip -1 > "$3"
  gzip -t "$3" || die "The dump file is corrupt."
  gzip -dc "$3" | tail -n 3 | grep -q 'Dump completed' || die "The dump did not finish (no 'Dump completed' marker)."
}

restore_db() { # cnf db file charset collation
  mysql --defaults-extra-file="$1" -e "DROP DATABASE IF EXISTS \`$2\`; CREATE DATABASE \`$2\` CHARACTER SET $4 COLLATE $5;"
  gzip -dc "$3" | mysql --defaults-extra-file="$1" --default-character-set=utf8mb4 "$2"
}

# ---------- always: machine and production checks -----------------------------------
[[ "$SRC_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "SRC_DB may only contain letters, digits and underscores."
command -v mysql >/dev/null 2>&1 || die "mysql client not found."
command -v mysqldump >/dev/null 2>&1 || die "mysqldump not found."
command -v gzip >/dev/null 2>&1 || die "gzip not found."

check_machine_region
SRC_REGION=$(server_region "$SRC_HOST" "$SRC_RG")
is_uae "$SRC_REGION" || die "Source server $SRC_HOST is in '$SRC_REGION', expected the UAE."
log "Source server region: $SRC_REGION"

mkdir -p "$WORK_DIR"
RUN_DIR="$WORK_DIR/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUN_DIR"
SRC_CNF="$RUN_DIR/src.cnf"; DST_CNF="$RUN_DIR/dst.cnf"; SCR_CNF="$RUN_DIR/scr.cnf"
msrc() { mysql --defaults-extra-file="$SRC_CNF" "$@"; }
mdst() { mysql --defaults-extra-file="$DST_CNF" "$@"; }
mscr() { mysql --defaults-extra-file="$SCR_CNF" "$@"; }

mk_cnf "$SRC_CNF" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$(get_password "$SRC_PASSWORD" "$SRC_PASSWORD_SECRET" SRC)"
msrc -N -e "SELECT 1" >/dev/null || die "Cannot connect to the source $SRC_HOST (private network? password?)."

# ---------- discover mode ---------------------------------------------------------------
if [ "$MODE" = discover ]; then
  log "Columns of $SRC_DB whose names suggest personal or health data (candidates only, check each one):"
  msrc -e "SELECT table_name AS tbl, column_name AS col, column_type AS type FROM information_schema.columns WHERE table_schema='${SRC_DB}' AND column_name REGEXP 'name|mail|phone|mobile|tel|address|city|birth|dob|gender|sex|nation|passport|emirates|eid|id_?no|id_?number|ssn|insur|diagnos|symptom|medic|prescri|allerg|note|comment|message|reason|password|token|secret|card|iban|account|lat|lng|location|ip_?addr' ORDER BY 1,2"
  exit 0
fi

# ---------- copy mode: guards ---------------------------------------------------------------
[[ "$DST_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "DST_DB may only contain letters, digits and underscores."
[[ "$DST_DB" == *test* || "$DST_DB" == *verify* ]] || die "DST_DB must contain 'test' or 'verify' (got '$DST_DB'). This script never writes to a production database."
if [ "$DST_HOST" = "$SRC_HOST" ] && [ "$DST_DB" = "$SRC_DB" ]; then die "Destination and source are the same database."; fi
[[ "$SCRATCH_DB" =~ ^[A-Za-z0-9_]+$ && "$SCRATCH_DB" == *verify* ]] || die "SCRATCH_DB must contain 'verify' (got '$SCRATCH_DB')."
if [ "$SCRATCH_HOST" = "$SRC_HOST" ] && [ "$SCRATCH_DB" = "$SRC_DB" ]; then die "Scratch and source are the same database."; fi
if [ "$SCRATCH_HOST" = "$DST_HOST" ] && [ "$SCRATCH_DB" = "$DST_DB" ]; then die "Scratch and destination are the same database."; fi
[ -n "$DST_USER" ] || die "Set DST_USER."

DST_REGION=$(server_region "$DST_HOST" "$DST_RG")
if is_uae "$DST_REGION"; then DST_IN_UAE=1; else DST_IN_UAE=0; fi
log "Destination server region: $DST_REGION"

USE_SCRATCH=0
if [ -n "$MASK_SQL" ]; then USE_SCRATCH=1; fi
if [ "$DST_IN_UAE" = 0 ]; then
  USE_SCRATCH=1
  [ -s "$MASK_SQL" ] || die "The destination is outside the UAE ($DST_REGION). Set MASK_SQL to a masking script; raw production data must not leave the UAE. (Run --discover to find candidate columns.)"
  [ -s "$MASK_CHECK_SQL" ] || die "Set MASK_CHECK_SQL to a script that returns 0 when nothing unmasked is left."
fi
if [ "$USE_SCRATCH" = 1 ]; then
  [ -s "$MASK_SQL" ] || die "MASK_SQL file not found: $MASK_SQL"
  [ -z "$MASK_CHECK_SQL" ] || [ -s "$MASK_CHECK_SQL" ] || die "MASK_CHECK_SQL file not found: $MASK_CHECK_SQL"
  [ -n "$SCRATCH_USER" ] || die "Set SCRATCH_USER to a UAE MySQL user that may create and drop '$SCRATCH_DB'."
  SCRATCH_REGION=$(server_region "$SCRATCH_HOST" "$SCRATCH_RG")
  is_uae "$SCRATCH_REGION" || die "The scratch server $SCRATCH_HOST is in '$SCRATCH_REGION'. It must be in the UAE."
  log "Scratch server region: $SCRATCH_REGION"
  mk_cnf "$SCR_CNF" "$SCRATCH_HOST" "$SCRATCH_PORT" "$SCRATCH_USER" "$(get_password "$SCRATCH_PASSWORD" "$SCRATCH_PASSWORD_SECRET" SCRATCH)"
  mscr -N -e "SELECT 1" >/dev/null || die "Cannot connect to the scratch server $SCRATCH_HOST as $SCRATCH_USER."
fi
mk_cnf "$DST_CNF" "$DST_HOST" "$DST_PORT" "$DST_USER" "$(get_password "$DST_PASSWORD" "$DST_PASSWORD_SECRET" DST)"
mdst -N -e "SELECT 1" >/dev/null || die "Cannot connect to the destination $DST_HOST as $DST_USER (is it reachable from this VM? firewall or private network?)."

VER=$(msrc -N -e "SELECT VERSION()")
read -r CS COLL < <(msrc -N -e "SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name='${SRC_DB}'") || true
[ -n "${CS:-}" ] || die "Database '$SRC_DB' not found on $SRC_HOST."
[[ "$CS" =~ ^[a-z0-9_]+$ && "$COLL" =~ ^[a-z0-9_]+$ ]] || die "Unexpected charset/collation: $CS / $COLL"
SIZE_MB=$(msrc -N -e "SELECT ROUND(COALESCE(SUM(data_length+index_length),0)/1024/1024,1) FROM information_schema.tables WHERE table_schema='${SRC_DB}'")
FREE_MB=$(df -Pm "$WORK_DIR" | awk 'NR==2{print $4}')

echo
echo "  Production  : $SRC_DB on $SRC_HOST ($SRC_REGION, MySQL $VER, about ${SIZE_MB} MB)  READ ONLY"
if [ "$USE_SCRATCH" = 1 ]; then
  echo "  Scratch     : $SCRATCH_DB on $SCRATCH_HOST (UAE), masked with $MASK_SQL, then dropped"
fi
echo "  Testing     : $DST_DB on $DST_HOST ($DST_REGION)  will be DROPPED and recreated"
if [ "$DST_IN_UAE" = 0 ]; then
  echo "  Data leaving the UAE: ONLY the masked copy, after $MASK_CHECK_SQL returns 0"
else
  echo "  Destination is in the UAE."
fi
if [ "$USE_SCRATCH" = 1 ] && [ "$SCRATCH_HOST" = "$SRC_HOST" ]; then
  echo "  NOTE        : the scratch copy sits on the production server for a few minutes (extra storage and load)."
fi
echo "  Temp files  : $RUN_DIR  (free space here: ${FREE_MB} MB, deleted at the end)"
echo
confirm "Replace the contents of '$DST_DB' on $DST_HOST." "$DST_DB"
if [ "$DST_IN_UAE" = 0 ]; then
  confirm "Only masked data will leave the UAE. Masking was approved by the PM." "MASKED" 1
fi

# ---------- stage 1: production -> dump ----------------------------------------------------
DUMP1="$RUN_DIR/prod.sql.gz"
log "Dumping production $SRC_DB (read only) ..."
dump_db "$SRC_CNF" "$SRC_DB" "$DUMP1"
log "Dump OK ($(du -h "$DUMP1" | cut -f1) compressed)."

FINAL="$DUMP1"
COMPARE_CNF="$SRC_CNF"; COMPARE_DB="$SRC_DB"

if [ "$USE_SCRATCH" = 1 ]; then
  # ---------- stage 2: scratch copy in the UAE, mask, check ---------------------------------
  SCRATCH_CREATED=1
  log "Restoring into the UAE scratch database $SCRATCH_DB ..."
  restore_db "$SCR_CNF" "$SCRATCH_DB" "$DUMP1" "$CS" "$COLL"
  rm -f "$DUMP1"
  log "Masking with $MASK_SQL ..."
  mscr "$SCRATCH_DB" < "$MASK_SQL"
  if [ -n "$MASK_CHECK_SQL" ]; then
    OUT=$(mscr -N "$SCRATCH_DB" < "$MASK_CHECK_SQL")
    TOTAL=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [[ "$line" =~ ^[0-9]+$ ]] || die "MASK_CHECK_SQL must return numbers only (got '$line')."
      TOTAL=$((TOTAL + line))
    done <<< "$OUT"
    [ "$TOTAL" = 0 ] || die "Mask check failed: $TOTAL unmasked values remain. Nothing was sent to $DST_HOST."
    log "Mask check passed."
  else
    log "WARNING: no MASK_CHECK_SQL given, the masking was not verified."
  fi
  FINAL="$RUN_DIR/masked.sql.gz"
  dump_db "$SCR_CNF" "$SCRATCH_DB" "$FINAL"
  COMPARE_CNF="$SCR_CNF"; COMPARE_DB="$SCRATCH_DB"
fi

# ---------- stage 3: restore into testing ---------------------------------------------------
log "Replacing $DST_DB on $DST_HOST ..."
restore_db "$DST_CNF" "$DST_DB" "$FINAL" "$CS" "$COLL"
log "Restore finished."

if [ "$COMPARE" = 1 ]; then
  log "Comparing row counts ($COMPARE_DB -> $DST_DB) ..."
  BAD=0; N=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [[ "$t" =~ ^[A-Za-z0-9_$]+$ ]] || { log "skipping table with unusual name: $t"; continue; }
    a=$(mysql --defaults-extra-file="$COMPARE_CNF" -N "$COMPARE_DB" -e "SELECT COUNT(*) FROM \`$t\`")
    b=$(mdst -N "$DST_DB" -e "SELECT COUNT(*) FROM \`$t\`")
    N=$((N+1))
    if [ "$a" != "$b" ]; then BAD=$((BAD+1)); printf '  DIFF  %-40s before=%s testing=%s\n' "$t" "$a" "$b"; fi
  done < <(mysql --defaults-extra-file="$COMPARE_CNF" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${COMPARE_DB}' AND table_type='BASE TABLE' ORDER BY 1")
  log "Compared $N tables, $BAD with a different count."
fi

echo
log "Done. The testing database $DST_DB now holds a copy of production as of this run."
log "Temp files and the scratch database are removed when the script exits."
