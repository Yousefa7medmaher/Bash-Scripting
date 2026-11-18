#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP="${1:?Usage: $0 path/to/backup.sql}"
REMOTE_USER="${REMOTE_USER:?Set REMOTE_USER}"
REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${REMOTE_PORT:-22}"
REMOTE_FILE="${REMOTE_FILE:?Set REMOTE_FILE}"

echo "=== 1. Check local backup ==="

if [[ ! -s "$BACKUP" ]]; then
    echo "ERROR: Backup file not found or empty: $BACKUP"
    exit 1
fi

ls -lh "$BACKUP"

if ! grep -aqE 'CREATE EXTENSION IF NOT EXISTS vector' "$BACKUP" ||
   ! grep -aqE 'CREATE TABLE public\.langchain_pg_embedding' "$BACKUP"; then
    echo "ERROR: This is not the expected pgvector backup."
    exit 1
fi

if grep -aqE '^[[:space:]]*(CREATE DATABASE|DROP DATABASE|\\connect|\\c)([[:space:]]|$)' "$BACKUP"; then
    echo "ERROR: Database-level commands found. Transfer cancelled."
    exit 1
fi

LOCAL_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
echo "Local SHA256: $LOCAL_SHA"

echo "=== 2. Transfer backup to server ==="
scp -P "$PORT" "$BACKUP" "$REMOTE:$REMOTE_FILE"

echo "=== 3. Verify transferred file ==="
REMOTE_SHA="$(ssh -p "$PORT" "$REMOTE" \
    "sha256sum '$REMOTE_FILE' | cut -d ' ' -f1")"

echo "Remote SHA256: $REMOTE_SHA"

if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    echo "ERROR: SHA256 mismatch. Do not restore this file."
    exit 1
fi

echo "SUCCESS: Backup transferred and checksum verified."
