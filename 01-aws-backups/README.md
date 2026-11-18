# AWS database backups

The scripts create RDS snapshots and local logical dumps for MySQL and
PostgreSQL. They require AWS CLI authentication plus the database clients
listed in each script; `v2` and `v3` also require Docker.

Set these variables before running:

```bash
export AWS_REGION=your-region
export MYSQL_INSTANCE=your-mysql-instance
export MYSQL_HOST=your-mysql-endpoint
export MYSQL_USER=your-mysql-user
export PG_INSTANCE=your-postgres-instance
export PG_HOST=your-postgres-endpoint
export PG_USER=your-postgres-user
export BACKUP_ROOT="$HOME/backups/rds" # optional
```

The scripts prompt for passwords and write backups, metadata, logs, and
checksums under `BACKUP_ROOT`. Keep that output private. `full-rds-backup-v2.sh`
and `full-rds-backup-v3.sh` use the official MySQL Docker client; compare the
PostgreSQL flags in `v3` before choosing it for a managed database.

These are operational scripts: snapshot creation and full database dumps can
incur cost and load. Verify the AWS account, region, permissions, and retention
policy first.
