#!/usr/bin/env bash
# Compare a local evidence folder with a user-maintained list of expected files.
set -Eeuo pipefail

SHOT_DIR="${SHOT_DIR:?Set SHOT_DIR}"
EXPECTED_FILES="${EXPECTED_FILES:?Set EXPECTED_FILES to a newline-delimited manifest}"

[[ -d "$SHOT_DIR" ]] || { echo "Evidence folder not found: $SHOT_DIR" >&2; exit 2; }
[[ -f "$EXPECTED_FILES" ]] || { echo "Manifest not found: $EXPECTED_FILES" >&2; exit 2; }

missing=0
expected=0
while IFS= read -r file || [[ -n "$file" ]]; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  expected=$((expected + 1))
  if [[ -s "$SHOT_DIR/$file" ]]; then
    printf 'OK       %s\n' "$file"
  else
    printf 'MISSING  %s\n' "$file"
    missing=$((missing + 1))
  fi
done < "$EXPECTED_FILES"

printf '%s of %s expected files are missing.\n' "$missing" "$expected"
((missing == 0))
