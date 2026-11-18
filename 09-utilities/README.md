# Utilities

| Script | Purpose |
| --- | --- |
| `check-shots.sh` | Compare an evidence directory against a supplied file manifest |
| `delete-matched-aws-resources.sh` | Find matching AWS resources; dry-run by default |
| `lint-shell-syntax.sh` | Run `bash -n` on repository shell scripts |
| `reorganize.sh` | Move local backups into a service-first directory layout |
| `submit-pr-review.sh` | Submit a user-provided GitHub review JSON payload |

The AWS deletion helper is destructive when passed `--execute`. It requires an
explicit resource-name pattern and region list, and checks for a backup
manifest by default. Review its dry-run output carefully; never use
`--skip-backup-check` casually.

The PR helper is dry-run by default and requires `GITHUB_REPOSITORY`,
`PULL_REQUEST_NUMBER`, and `REVIEW_PAYLOAD`. The file organizer moves backup
files; run it on a copy or inspect the source and destination first.
