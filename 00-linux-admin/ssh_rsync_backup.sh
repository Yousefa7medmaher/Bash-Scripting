#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${SOURCE_PATH:?Set SOURCE_PATH}"
REMOTE_USER="${REMOTE_USER:?Set REMOTE_USER}"
REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST}"
REMOTE_DIR="${REMOTE_DIR:?Set REMOTE_DIR}"
BACKUP_LOG="${BACKUP_LOG:-backup.log}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

[[ -e "$SOURCE_PATH" ]] || { echo "Source path not found: $SOURCE_PATH" >&2; exit 1; }

if rsync -avz -- "$SOURCE_PATH" "${REMOTE}:${REMOTE_DIR%/}/" >> "$BACKUP_LOG" 2>&1; then
  printf 'Backup completed at %s\n' "$(date -u +%FT%TZ)" | tee -a "$BACKUP_LOG"
else
  status=$?
  printf 'Backup failed at %s (rsync exit %s)\n' "$(date -u +%FT%TZ)" "$status" \
    | tee -a "$BACKUP_LOG" >&2
  exit "$status"
fi
