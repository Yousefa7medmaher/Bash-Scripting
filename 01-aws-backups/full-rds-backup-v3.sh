#!/usr/bin/env bash
set -Eeuo pipefail

# Full RDS backup for MySQL and PostgreSQL instances.
#
# MySQL logical dump uses the official MySQL 8.4 client in Docker,
# avoiding MariaDB mysqldump/MySQL 8.4 TLS compatibility issues.
#
# Re-run safely after a partial failure with:
#   SKIP_SNAPSHOTS=1 ./full-rds-backup-v2.sh
#
# Requirements:
#   aws, docker, mysql, psql, pg_dumpall, gzip, sha256sum

REGION="${AWS_REGION:?Set AWS_REGION to the target region}"
MYSQL_INSTANCE="${MYSQL_INSTANCE:?Set MYSQL_INSTANCE}"
MYSQL_USER="${MYSQL_USER:?Set MYSQL_USER}"
MYSQL_PORT="3306"
MYSQL_HOST="${MYSQL_HOST:?Set MYSQL_HOST}"
MYSQL_IMAGE="mysql:8.4"

PG_INSTANCE="${PG_INSTANCE:?Set PG_INSTANCE}"
PG_USER="${PG_USER:?Set PG_USER}"
PG_PORT="5432"
PG_HOST="${PG_HOST:?Set PG_HOST}"

SKIP_SNAPSHOTS="${SKIP_SNAPSHOTS:-0}"

BASE_ROOT="${BACKUP_ROOT:-${HOME}/backups/rds}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RUN_TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BASE_ROOT}/${RUN_DATE}"

mkdir -p "${BACKUP_DIR}"/{metadata,dumps/mysql,dumps/postgres,snapshots,logs}
LOG_FILE="${BACKUP_DIR}/logs/full-backup-v2-${RUN_TS}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

MYSQL_DUMP="${BACKUP_DIR}/dumps/mysql/${MYSQL_INSTANCE}-full-${RUN_DATE}.sql.gz"
MYSQL_TMP="${MYSQL_DUMP}.part"
MYSQL_LOG="${BACKUP_DIR}/logs/${MYSQL_INSTANCE}-mysqldump-${RUN_TS}.log"
PG_DUMP="${BACKUP_DIR}/dumps/postgres/${PG_INSTANCE}-full-${RUN_DATE}.sql.gz"
PG_TMP="${PG_DUMP}.part"
PG_LOG="${BACKUP_DIR}/logs/${PG_INSTANCE}-pg_dumpall-${RUN_TS}.log"
MYSQL_CNF=""

cleanup() {
  [[ -n "${MYSQL_CNF}" ]] && rm -f "${MYSQL_CNF}" || true
  rm -f "${MYSQL_TMP}" "${PG_TMP}" 2>/dev/null || true
  unset MYSQL_PASSWORD PG_PASSWORD || true
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_db_available() {
  local db="$1"
  echo
  echo "==> Waiting for ${db} to be available..."
  aws rds wait db-instance-available \
    --region "${REGION}" \
    --db-instance-identifier "${db}"
  echo "    ${db}: available"
}

create_snapshot() {
  local db="$1"
  local snap="$2"

  echo
  echo "==> Creating RDS snapshot: ${snap}"
  aws rds create-db-snapshot \
    --region "${REGION}" \
    --db-instance-identifier "${db}" \
    --db-snapshot-identifier "${snap}" >/dev/null

  echo "==> Waiting for snapshot to become available..."
  aws rds wait db-snapshot-available \
    --region "${REGION}" \
    --db-snapshot-identifier "${snap}"

  aws rds describe-db-snapshots \
    --region "${REGION}" \
    --db-snapshot-identifier "${snap}" \
    --output json \
    > "${BACKUP_DIR}/metadata/${db}-snapshot.json"

  echo "    Snapshot available: ${snap}"
}

latest_manual_snapshot() {
  local db="$1"
  aws rds describe-db-snapshots \
    --region "${REGION}" \
    --db-instance-identifier "${db}" \
    --snapshot-type manual \
    --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' \
    --output text
}

for cmd in aws docker mysql psql pg_dumpall gzip sha256sum; do
  require_cmd "$cmd"
done

export AWS_PAGER=""

# Capture instance metadata before backup.
echo "==> Capturing RDS instance metadata"
aws rds describe-db-instances \
  --region "${REGION}" \
  --db-instance-identifier "${MYSQL_INSTANCE}" \
  --output json \
  > "${BACKUP_DIR}/metadata/${MYSQL_INSTANCE}-instance.json"

aws rds describe-db-instances \
  --region "${REGION}" \
  --db-instance-identifier "${PG_INSTANCE}" \
  --output json \
  > "${BACKUP_DIR}/metadata/${PG_INSTANCE}-instance.json"

wait_db_available "${MYSQL_INSTANCE}"
wait_db_available "${PG_INSTANCE}"

MYSQL_SNAPSHOT=""
PG_SNAPSHOT=""

if [[ "${SKIP_SNAPSHOTS}" == "1" ]]; then
  echo
  echo "==> SKIP_SNAPSHOTS=1: reusing latest available manual snapshots"
  MYSQL_SNAPSHOT="$(latest_manual_snapshot "${MYSQL_INSTANCE}")"
  PG_SNAPSHOT="$(latest_manual_snapshot "${PG_INSTANCE}")"

  [[ -n "${MYSQL_SNAPSHOT}" && "${MYSQL_SNAPSHOT}" != "None" ]] || fail "No manual snapshot found for ${MYSQL_INSTANCE}"
  [[ -n "${PG_SNAPSHOT}" && "${PG_SNAPSHOT}" != "None" ]] || fail "No manual snapshot found for ${PG_INSTANCE}"

  aws rds describe-db-snapshots --region "${REGION}" --db-snapshot-identifier "${MYSQL_SNAPSHOT}" --output json > "${BACKUP_DIR}/metadata/${MYSQL_INSTANCE}-snapshot.json"
  aws rds describe-db-snapshots --region "${REGION}" --db-snapshot-identifier "${PG_SNAPSHOT}" --output json > "${BACKUP_DIR}/metadata/${PG_INSTANCE}-snapshot.json"

  echo "    Reusing MySQL snapshot: ${MYSQL_SNAPSHOT}"
  echo "    Reusing PostgreSQL snapshot: ${PG_SNAPSHOT}"
else
  MYSQL_SNAPSHOT="${MYSQL_INSTANCE}-migration-${RUN_TS}"
  PG_SNAPSHOT="${PG_INSTANCE}-migration-${RUN_TS}"
  create_snapshot "${MYSQL_INSTANCE}" "${MYSQL_SNAPSHOT}"
  create_snapshot "${PG_INSTANCE}" "${PG_SNAPSHOT}"
fi

echo
echo "==> Enter database passwords"
read -r -s -p "MySQL password (${MYSQL_USER}@${MYSQL_INSTANCE}): " MYSQL_PASSWORD
printf '\n'
read -r -s -p "PostgreSQL password (${PG_USER}@${PG_INSTANCE}): " PG_PASSWORD
printf '\n'

# ---- MySQL connection test using local mysql client ----
echo
echo "==> Testing MySQL connection"
env MYSQL_PWD="${MYSQL_PASSWORD}" mysql \
  --connect-timeout=15 \
  -h "${MYSQL_HOST}" \
  -P "${MYSQL_PORT}" \
  -u "${MYSQL_USER}" \
  -e "SELECT VERSION(), CURRENT_USER(), @@hostname;"

# ---- MySQL logical dump using official MySQL 8.4 client ----
echo "==> Preparing official MySQL 8.4 dump client"
docker image inspect "${MYSQL_IMAGE}" >/dev/null 2>&1 || docker pull "${MYSQL_IMAGE}"

echo "==> MySQL dump client version"
docker run --rm "${MYSQL_IMAGE}" mysqldump --version

MYSQL_CNF="$(mktemp)"
chmod 600 "${MYSQL_CNF}"
cat > "${MYSQL_CNF}" <<EOF_MYSQL_CNF
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}
ssl-mode=REQUIRED
EOF_MYSQL_CNF

echo "==> Creating MySQL logical dump with official MySQL 8.4 client"
rm -f "${MYSQL_DUMP}" "${MYSQL_TMP}" "${MYSQL_LOG}"
set +e
{
  docker run --rm -i \
    --mount type=bind,source="${MYSQL_CNF}",target=/tmp/backup.cnf,readonly \
    "${MYSQL_IMAGE}" \
    mysqldump \
      --defaults-extra-file=/tmp/backup.cnf \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      --no-tablespaces \
      --hex-blob \
      --set-gtid-purged=OFF \
      --all-databases \
      2>"${MYSQL_LOG}" | gzip -9 > "${MYSQL_TMP}"
  MYSQL_RC="${PIPESTATUS[0]}"
}
set -e

rm -f "${MYSQL_CNF}"
MYSQL_CNF=""

if [[ "${MYSQL_RC}" -ne 0 || ! -s "${MYSQL_TMP}" ]]; then
  echo "ERROR: MySQL dump failed (official mysqldump exit code ${MYSQL_RC})."
  cat "${MYSQL_LOG}" >&2 || true
  exit 1
fi

mv "${MYSQL_TMP}" "${MYSQL_DUMP}"
gzip -t "${MYSQL_DUMP}"
echo "    MySQL dump: ${MYSQL_DUMP}"
ls -lh "${MYSQL_DUMP}"

# ---- PostgreSQL logical dump ----
# RDS PostgreSQL is not a true superuser; --no-role-passwords avoids pg_authid.
# --no-tablespaces keeps the dump portable to a normal PostgreSQL server.
echo
echo "==> Testing PostgreSQL connection"
env PGPASSWORD="${PG_PASSWORD}" psql \
  "host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres connect_timeout=15" \
  -Atc "SELECT version();"

echo "==> Creating PostgreSQL full instance dump"
rm -f "${PG_DUMP}" "${PG_TMP}" "${PG_LOG}"
set +e
{
  env PGPASSWORD="${PG_PASSWORD}" pg_dumpall \
    -h "${PG_HOST}" \
    -p "${PG_PORT}" \
    -U "${PG_USER}" \
    --database=postgres \
    --no-role-passwords \
    --no-tablespaces \
    2>"${PG_LOG}" | gzip -9 > "${PG_TMP}"
  PG_RC="${PIPESTATUS[0]}"
}
set -e

if [[ "${PG_RC}" -ne 0 || ! -s "${PG_TMP}" ]]; then
  echo "ERROR: PostgreSQL dump failed (pg_dumpall exit code ${PG_RC})."
  cat "${PG_LOG}" >&2 || true
  exit 1
fi

mv "${PG_TMP}" "${PG_DUMP}"
gzip -t "${PG_DUMP}"
echo "    PostgreSQL dump: ${PG_DUMP}"
ls -lh "${PG_DUMP}"

# ---- Inventories ----
echo
echo "==> Saving PostgreSQL database inventory"
env PGPASSWORD="${PG_PASSWORD}" psql \
  "host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=postgres connect_timeout=15" \
  -P pager=off \
  -Atc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1;" \
  > "${BACKUP_DIR}/metadata/${PG_INSTANCE}-databases.txt"

echo "==> Saving MySQL database inventory"
env MYSQL_PWD="${MYSQL_PASSWORD}" mysql \
  --connect-timeout=15 \
  -h "${MYSQL_HOST}" \
  -P "${MYSQL_PORT}" \
  -u "${MYSQL_USER}" \
  -N -B \
  -e "SHOW DATABASES;" \
  > "${BACKUP_DIR}/metadata/${MYSQL_INSTANCE}-databases.txt"

# ---- Checksums ----
echo
echo "==> Generating SHA-256 checksums"
(
  cd "${BACKUP_DIR}"
  sha256sum \
    "dumps/mysql/${MYSQL_INSTANCE}-full-${RUN_DATE}.sql.gz" \
    "dumps/postgres/${PG_INSTANCE}-full-${RUN_DATE}.sql.gz" \
    > "checksums.sha256"
)

# ---- Documentation ----
cat > "${BACKUP_DIR}/README.md" <<README
# Full RDS Backup — ${RUN_DATE}

Run timestamp (UTC): ${RUN_TS}
Region: ${REGION}

## RDS snapshots
- ${MYSQL_INSTANCE}: ${MYSQL_SNAPSHOT}
- ${PG_INSTANCE}: ${PG_SNAPSHOT}

## Local logical dumps
- MySQL: dumps/mysql/${MYSQL_INSTANCE}-full-${RUN_DATE}.sql.gz
- PostgreSQL: dumps/postgres/${PG_INSTANCE}-full-${RUN_DATE}.sql.gz

## Dump client/runtime
- MySQL dump client: official Docker image ${MYSQL_IMAGE}
- PostgreSQL dump client: $(pg_dumpall --version)

## Integrity
- gzip integrity checked for both dumps
- SHA-256: checksums.sha256

## Restore examples

### MySQL

gunzip -c dumps/mysql/${MYSQL_INSTANCE}-full-${RUN_DATE}.sql.gz | mysql -h <TARGET_HOST> -P 3306 -u <TARGET_USER> -p

### PostgreSQL

gunzip -c dumps/postgres/${PG_INSTANCE}-full-${RUN_DATE}.sql.gz | psql -h <TARGET_HOST> -p 5432 -U <TARGET_USER> -d postgres

The PostgreSQL dump is a pg_dumpall SQL dump containing roles/global objects and all dumpable databases.
README

# Save tool versions.
{
  echo "AWS CLI: $(aws --version 2>&1)"
  echo "Docker: $(docker --version)"
  echo "Local MySQL client: $(mysql --version)"
  echo "PostgreSQL: $(psql --version)"
} > "${BACKUP_DIR}/metadata/tool-versions.txt"

echo
echo "============================================="
echo "FULL BACKUP COMPLETED SUCCESSFULLY"
echo "============================================="
echo "Backup directory: ${BACKUP_DIR}"
echo "MySQL snapshot:      ${MYSQL_SNAPSHOT}"
echo "PostgreSQL snapshot: ${PG_SNAPSHOT}"
echo "MySQL dump:          ${MYSQL_DUMP}"
echo "PostgreSQL dump:     ${PG_DUMP}"
echo "Checksums:           ${BACKUP_DIR}/checksums.sha256"
echo "Log:                 ${LOG_FILE}"

trap - EXIT
cleanup
