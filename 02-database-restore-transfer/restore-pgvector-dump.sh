#!/usr/bin/env bash
# Upload and restore a plain-SQL PostgreSQL dump into a pgvector container.
#
# Usage:
#   ./restore-pgvector-dump.sh path/to/dump.sql
#   SSH_USER=... SSH_HOST=... DB_NAME=... DB_USER=... CONTAINER_FILTER=... ./restore-pgvector-dump.sh path/to/dump.sql
#
# You'll be asked for the SSH password once (connection is reused),
# and for the sudo password once on the server.

set -euo pipefail

DUMP="${1:?usage: $0 path/to/dump.sql}"

# ---- config ---------------------------------------------------------------
SSH_USER="${SSH_USER:?Set SSH_USER}"
SSH_HOST="${SSH_HOST:?Set SSH_HOST}"
SSH_PORT="${SSH_PORT:-22}"
DB_NAME="${DB_NAME:?Set DB_NAME}"
DB_USER="${DB_USER:?Set DB_USER}"
CONTAINER_FILTER="${CONTAINER_FILTER:?Set CONTAINER_FILTER}"
REMOTE_DIR="${REMOTE_DIR:-restore-staging}" # relative to remote $HOME
STAMP="$(date +%Y%m%d_%H%M%S)"
# ---------------------------------------------------------------------------

[[ -f "$DUMP" ]] || { echo "Dump not found: $DUMP"; exit 1; }

echo "==> [1/5] Checking dump"
if grep -qE '^\\connect|^CREATE DATABASE' "$DUMP"; then
  echo "!! Dump contains \\connect / CREATE DATABASE (looks like pg_dumpall)."
  echo "!! It may restore into other databases. Set FORCE=1 to continue anyway."
  [[ "${FORCE:-0}" == "1" ]] || exit 1
fi
echo "    vector columns found: $(grep -c 'vector(' "$DUMP" || true)"

# Reuse one SSH connection so the password is asked only once
CM="$HOME/.ssh/cm-${SSH_USER}-${SSH_HOST}-${SSH_PORT}"
mkdir -p "$HOME/.ssh"
SSH_OPTS=(-p "$SSH_PORT" -o ControlMaster=auto -o ControlPath="$CM" -o ControlPersist=15m -o ServerAliveInterval=30)
SCP_OPTS=(-P "$SSH_PORT" -o ControlPath="$CM" -o ServerAliveInterval=30)
TARGET="${SSH_USER}@${SSH_HOST}"

echo "==> [2/5] Compressing dump"
# Persistent work dir so a re-run reuses the .gz and resumes the upload
TMP="$HOME/kb_upload"
mkdir -p "$TMP"
GZ_NAME="$(basename "$DUMP" .sql).sql.gz"
GZ="$TMP/$GZ_NAME"
if [[ -f "$GZ" && "$GZ" -nt "$DUMP" ]]; then
  echo "    reusing existing $GZ"
else
  gzip -1 -c "$DUMP" > "$GZ.part" && mv "$GZ.part" "$GZ"
fi
ls -lh "$GZ"

# Remote script (variables expanded here, locally)
cat > "$TMP/remote_restore.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ~/$REMOTE_DIR
sudo -v

CID=\$(sudo dev-docker ps --filter "name=$CONTAINER_FILTER" -q | head -1)
[[ -n "\$CID" ]] || { echo "pgvector container not found"; exit 1; }
echo "    container: \$CID"

PSQL="sudo dev-docker exec -i \$CID psql -U $DB_USER -d $DB_NAME"

echo "==> [4/5] Backing up current $DB_NAME before restore"
sudo dev-docker exec \$CID pg_dump -U $DB_USER $DB_NAME | gzip > before_restore_$STAMP.sql.gz
ls -lh before_restore_$STAMP.sql.gz

echo "==> Restoring (this can take a while)..."
# Drop OWNER lines so all objects belong to $DB_USER
zcat $GZ_NAME \\
  | sed -E '/^ALTER .* OWNER TO /d' \\
  | \$PSQL -q > restore_$STAMP.log 2>&1 || true

echo "    errors in log: \$(grep -c ERROR restore_$STAMP.log || true)"
grep ERROR restore_$STAMP.log | sort | uniq -c | sort -rn | head -10 || true

echo "==> [5/5] Verifying"
\$PSQL -c "ANALYZE;" >/dev/null
\$PSQL -c "SELECT extname, extversion FROM pg_extension;"
\$PSQL -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 20;"

echo "Done. Log: ~/$REMOTE_DIR/restore_$STAMP.log"
echo "Uploaded dump kept at ~/$REMOTE_DIR/$GZ_NAME (delete when happy)."
EOF

echo "==> [3/5] Uploading to $TARGET:~/$REMOTE_DIR"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/$REMOTE_DIR"
scp "${SCP_OPTS[@]}" "$TMP/remote_restore.sh" "$TARGET:~/$REMOTE_DIR/"

# rsync resumes partial uploads; retry until it finishes
RSH="ssh -p $SSH_PORT -o ControlPath=$CM -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
for i in $(seq 1 30); do
  if rsync -P --partial --append-verify --timeout=60 -e "$RSH" "$GZ" "$TARGET:~/$REMOTE_DIR/"; then
    break
  fi
  echo "    upload interrupted, retry $i/30 in 5s..."
  sleep 5
  [[ $i == 30 ]] && { echo "Upload failed"; exit 1; }
done

ssh -t "${SSH_OPTS[@]}" "$TARGET" "bash ~/$REMOTE_DIR/remote_restore.sh"
