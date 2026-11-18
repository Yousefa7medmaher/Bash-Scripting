#!/usr/bin/env bash
# Fast upload of a backup to a configured remote server (upload only, no restore).
# Splits the file into chunks and uploads them over several parallel SSH
# connections (each connection is slow, many together are faster).
# Safe to re-run: finished chunks are skipped, partial ones resume.
#
# Usage:
#   SSH_USER=... SSH_HOST=... ./upload_kb.sh path/to/backup.sql
#   JOBS=8 CHUNK=5M ./upload_kb.sh ...      # tune parallelism / chunk size

set -euo pipefail

SRC="${1:?Usage: $0 path/to/backup.sql[.gz]}"

SSH_USER="${SSH_USER:?Set SSH_USER}"
SSH_HOST="${SSH_HOST:?Set SSH_HOST}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-restore-staging}"
JOBS="${JOBS:-6}"
CHUNK="${CHUNK:-10M}"
WORK="$HOME/kb_upload"

TARGET="${SSH_USER}@${SSH_HOST}"
SSH_OPTS="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

[[ -f "$SRC" ]] || { echo "File not found: $SRC"; exit 1; }
mkdir -p "$WORK"

# ---- 1. compressed file -----------------------------------------------------
if [[ "$SRC" == *.gz ]]; then
  GZ="$SRC"
else
  GZ="$WORK/$(basename "$SRC" .sql).sql.gz"
  if [[ -f "$GZ" && "$GZ" -nt "$SRC" ]]; then
    echo "==> Reusing $GZ"
  else
    echo "==> Compressing (one time)..."
    if command -v pigz >/dev/null; then pigz -1 -c "$SRC" > "$GZ.part"; else gzip -1 -c "$SRC" > "$GZ.part"; fi
    mv "$GZ.part" "$GZ"
  fi
fi
NAME="$(basename "$GZ")"
ls -lh "$GZ"

# ---- 2. SSH key (password asked once, only the first time) -----------------
if ! ssh $SSH_OPTS "$TARGET" true 2>/dev/null; then
  echo "==> Setting up SSH key (enter the server password once)"
  [[ -f "$HOME/.ssh/id_ed25519" ]] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -q
  ssh-copy-id -p "$SSH_PORT" -i "$HOME/.ssh/id_ed25519.pub" "$TARGET"
fi

# ---- 3. split into chunks ---------------------------------------------------
PARTS="$WORK/parts_${NAME}"
if [[ ! -f "$PARTS/.done" ]]; then
  echo "==> Splitting into $CHUNK chunks"
  rm -rf "$PARTS"; mkdir -p "$PARTS"
  split -b "$CHUNK" -d -a 4 "$GZ" "$PARTS/part_"
  ( cd "$WORK" && sha256sum "$GZ" | awk '{print $1}' > "$PARTS/.sha256" )
  touch "$PARTS/.done"
fi
TOTAL=$(ls "$PARTS"/part_* | wc -l)
LOCAL_SHA=$(cat "$PARTS/.sha256")
echo "    $TOTAL chunks, sha256 $LOCAL_SHA"

ssh $SSH_OPTS "$TARGET" "mkdir -p ~/$REMOTE_DIR/parts_${NAME}"

# ---- 4. parallel upload -----------------------------------------------------
echo "==> Uploading with $JOBS parallel connections..."
export SSH_OPTS TARGET REMOTE_DIR NAME TOTAL
upload_one() {
  local f="$1" b; b=$(basename "$f")
  for i in $(seq 1 20); do
    if rsync -q --partial --append-verify --timeout=60 -e "ssh $SSH_OPTS" \
         "$f" "$TARGET:~/$REMOTE_DIR/parts_${NAME}/$b"; then
      echo "    ok  $b"
      return 0
    fi
    sleep 3
  done
  echo "    FAIL $b"; return 1
}
export -f upload_one

START=$(date +%s)
ls "$PARTS"/part_* | xargs -P "$JOBS" -I{} bash -c 'upload_one "$@"' _ {} || true

# Final pass: re-sends anything missing or incomplete
rsync -r --partial --size-only --timeout=60 -e "ssh $SSH_OPTS" \
  "$PARTS"/part_* "$TARGET:~/$REMOTE_DIR/parts_${NAME}/"
echo "    upload took $(( ($(date +%s) - START) / 60 )) min"

# ---- 5. join + verify on the server ----------------------------------------
echo "==> Joining and verifying on server"
ssh $SSH_OPTS "$TARGET" bash -s <<EOF
set -e
cd ~/$REMOTE_DIR
cat parts_${NAME}/part_* > ${NAME}.joining
SHA=\$(sha256sum ${NAME}.joining | awk '{print \$1}')
if [[ "\$SHA" == "$LOCAL_SHA" ]]; then
  mv ${NAME}.joining ${NAME}
  rm -rf parts_${NAME}
  ls -lh ~/$REMOTE_DIR/${NAME}
  echo "OK: checksum matches"
else
  rm -f ${NAME}.joining
  echo "Checksum mismatch - re-run the script"; exit 1
fi
EOF

echo "==> Done. File on server: ~/$REMOTE_DIR/$NAME"
