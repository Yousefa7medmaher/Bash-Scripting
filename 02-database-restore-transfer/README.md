# Database restore and transfer

| Script | Purpose |
| --- | --- |
| `transfer_mariadb_backup.sh` | Validate a MariaDB dump, copy it over SSH, and compare checksums |
| `transfer_pgvector_backup.sh` | Validate a pgvector dump, copy it over SSH, and compare checksums |
| `restore-pgvector-dump.sh` | Upload a PostgreSQL dump and restore it into a configured container |

The transfer scripts take a local dump path as their first argument and require
`REMOTE_USER`, `REMOTE_HOST`, and `REMOTE_FILE`; `REMOTE_PORT` defaults to 22.
The restore script takes a plain SQL dump path and requires `SSH_USER`,
`SSH_HOST`, `DB_NAME`, `DB_USER`, and `CONTAINER_FILTER`. It uses SSH, rsync,
gzip, and a remote Docker-compatible CLI (`dev-docker` in the generated remote
script).

Restores are data-destructive even when a pre-restore dump is created. Inspect
the target, dump format, and remote commands before use. The duplicate copies
were consolidated; use the canonical restore script in this folder.
