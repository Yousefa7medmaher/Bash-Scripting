#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="${LOG_DIR:?Set LOG_DIR}"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-5000000}"
MAX_LOG_AGE_DAYS="${MAX_LOG_AGE_DAYS:-30}"

[[ -d "$LOG_DIR" ]] || { echo "Log directory not found: $LOG_DIR" >&2; exit 1; }
[[ "$MAX_LOG_SIZE_BYTES" =~ ^[0-9]+$ && "$MAX_LOG_AGE_DAYS" =~ ^[0-9]+$ ]] \
  || { echo "Log size and age limits must be non-negative integers." >&2; exit 2; }

shopt -s nullglob
for log_file in "$LOG_DIR"/*.log; do
  [[ -f "$log_file" ]] || continue
  size="$(stat -c '%s' -- "$log_file")"
  if ((size > MAX_LOG_SIZE_BYTES)); then
    rotated_file="${log_file}.$(date -u +%Y%m%dT%H%M%S)"
    mv -- "$log_file" "$rotated_file"
    gzip -- "$rotated_file"
    printf 'Rotated %s\n' "$log_file"
  fi
done

find "$LOG_DIR" -type f -name '*.gz' -mtime "+$MAX_LOG_AGE_DAYS" -print -delete
