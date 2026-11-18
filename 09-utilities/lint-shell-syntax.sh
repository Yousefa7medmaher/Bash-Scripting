#!/usr/bin/env bash
# Run a syntax-only check over every shell script in this repository.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
checked=0

while IFS= read -r -d '' script; do
  checked=$((checked + 1))
  if bash -n "$script"; then
    printf 'OK   %s\n' "${script#"$ROOT"/}"
  else
    printf 'FAIL %s\n' "${script#"$ROOT"/}" >&2
    failures=$((failures + 1))
  fi
done < <(find "$ROOT" -type f -name '*.sh' -print0)

printf 'Checked %s scripts; %s syntax failure(s).\n' "$checked" "$failures"
((failures == 0))
