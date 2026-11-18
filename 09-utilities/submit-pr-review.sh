#!/usr/bin/env bash
# Submit a prepared GitHub pull-request review payload.
# The payload must be a JSON file in GitHub's pull-request review format.
set -Eeuo pipefail

REPOSITORY="${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY as owner/name}"
PULL_REQUEST="${PULL_REQUEST_NUMBER:?Set PULL_REQUEST_NUMBER}"
REVIEW_PAYLOAD="${REVIEW_PAYLOAD:?Set REVIEW_PAYLOAD to a JSON file}"

[[ "$PULL_REQUEST" =~ ^[0-9]+$ ]] || { echo "PULL_REQUEST_NUMBER must be numeric." >&2; exit 2; }
[[ -s "$REVIEW_PAYLOAD" ]] || { echo "Review payload is missing or empty." >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI (gh) is required." >&2; exit 2; }
gh auth status >/dev/null

if [[ "${DRY_RUN:-1}" == "1" ]]; then
  echo "Dry run. Review payload will not be submitted:"
  cat "$REVIEW_PAYLOAD"
  exit 0
fi

gh api --method POST "repos/$REPOSITORY/pulls/$PULL_REQUEST/reviews" \
  --input "$REVIEW_PAYLOAD"
