# Security and dependency helpers

| Script | Purpose |
| --- | --- |
| `check-trivyignore.sh` | Estimate the impact of removing a Trivy ignore file |
| `fix-trivy-cves.sh` | Upgrade selected dependencies, validate, and clean ignore entries |
| `dependency-migration-preflight.sh` | Inspect and optionally apply a guarded NestJS/TypeORM migration |

`fix-trivy-cves.sh` requires `REPO_DIR`; the preflight helper must be run from
inside the target Git repository. The scripts can modify dependency manifests,
source files, tags, or ignore files. Start with their read-only/preflight
modes, review the diff, and run tests in the target application before applying
any changes.
