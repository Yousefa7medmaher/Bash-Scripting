# Duplicate review files

The duplicate restore script was consolidated into
[`02-database-restore-transfer/restore-pgvector-dump.sh`](../02-database-restore-transfer/restore-pgvector-dump.sh).
Use that canonical script and supply the connection settings through environment
variables; do not keep separate copies with per-environment values.
