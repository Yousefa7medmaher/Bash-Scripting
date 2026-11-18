#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP="${1:?Usage: $0 path/to/backup.sql}"
REMOTE_USER="${REMOTE_USER:?Set REMOTE_USER}"
REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${REMOTE_PORT:-22}"
REMOTE_FILE="${REMOTE_FILE:?Set REMOTE_FILE}"

echo "=== 1. Check MariaDB backup ==="

test -s "$BACKUP" || {
    echo "ERROR: Backup file missing: $BACKUP"
    exit 1
}

TABLES="$(grep -acE '^[[:space:]]*CREATE TABLE[[:space:]]' "$BACKUP" || true)"

if [[ "$TABLES" -lt 1 ]]; then
    echo "ERROR: No CREATE TABLE statements found. Transfer cancelled."
    exit 1
fi

if grep -aqE 'CREATE EXTENSION.*vector' "$BACKUP"; then
    echo "ERROR: This looks like a PostgreSQL backup."
    exit 1
fi

echo "Backup file:"
ls -lh "$BACKUP"
echo "CREATE TABLE statements: $TABLES"

echo "=== Database names and dump metadata ==="
grep -aEi '^[[:space:]]*(USE[[:space:]]|CREATE DATABASE|-- Current Database:|-- Host:)' \
    "$BACKUP" | sed -n '1,15p' || true

LOCAL_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
echo "Local SHA256: $LOCAL_SHA"

echo "=== 2. Transfer backup ==="
scp -P "$PORT" "$BACKUP" "$REMOTE:$REMOTE_FILE"

echo "=== 3. Verify transferred file ==="
REMOTE_SHA="$(ssh -p "$PORT" "$REMOTE" \
    "sha256sum '$REMOTE_FILE' | cut -d ' ' -f1")"

echo "Remote SHA256: $REMOTE_SHA"

if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    echo "ERROR: SHA256 mismatch. Do not restore."
    exit 1
fi

echo "SUCCESS: MariaDB backup transferred and checksum verified."
