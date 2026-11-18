# Linux administration

This folder contains general-purpose host administration examples:

- `rotate_logs.sh` rotates oversized `.log` files and deletes old compressed
  logs under the explicitly configured `LOG_DIR`.
- `ssh_rsync_backup.sh` copies a chosen source path to an explicitly configured
  remote host and directory.
- `system_monitor.sh` checks Linux CPU, memory, and root filesystem usage.

Set `LOG_DIR` before running the log rotator. Set `SOURCE_PATH`, `REMOTE_USER`,
`REMOTE_HOST`, and `REMOTE_DIR` before running the rsync example. Monitoring
thresholds can be set with `CPU_THRESHOLD`, `MEMORY_THRESHOLD`, and
`DISK_THRESHOLD`; each defaults to 80 percent.

Review the deletion age and remote target carefully before scheduling either
script.
