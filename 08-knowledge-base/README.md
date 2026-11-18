# Knowledge-base backup upload

`upload_kb.sh` compresses a local SQL dump when needed, splits it into chunks,
uploads chunks in parallel over SSH, then joins and verifies the remote file.
It does not restore the dump.

Usage:

```bash
SSH_USER=your-user SSH_HOST=your-host ./upload_kb.sh path/to/backup.sql
```

`SSH_PORT` defaults to 22. Optional `JOBS` and `CHUNK` values tune parallelism
and chunk size. The script may create an SSH key if key authentication is not
configured. Protect the local and remote dump files and verify the remote
destination before running.
