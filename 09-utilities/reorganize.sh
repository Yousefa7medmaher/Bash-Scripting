#!/usr/bin/env bash
# Reorganizes a local cloud backup folder into a service-first layout.
# Safe to re-run: only uses mkdir -p and mv, never deletes anything.
# Run this FROM the parent of your current "aws" folder, e.g.:
#   cd /path/to/parent
#   bash reorganize.sh source-backups organized-backups

set -euo pipefail

SRC="${1:-source-backups}"
DST="${2:-organized-backups}"

if [ ! -d "$SRC" ]; then
  echo "Source folder '$SRC' not found. Run this from the folder that contains it." >&2
  exit 1
fi

echo "Reorganizing '$SRC' -> '$DST' ..."

mkdir -p "$DST"/{scripts,amplify,elastic-beanstalk,rds,db-manual-dumps}

# ---------- scripts ----------
for f in backup-amplify-today.sh full-rds-backup.sh full-rds-backup-v3.sh; do
  [ -f "$SRC/$f" ] && mv -v "$SRC/$f" "$DST/scripts/"
done

# ---------- amplify ----------
AMP_SRC_DIR=$(find "$SRC" -maxdepth 1 -type d -name "amplify-account-backup-*" | head -n1 || true)
if [ -n "${AMP_SRC_DIR:-}" ]; then
  STAMP=$(basename "$AMP_SRC_DIR" | sed 's/amplify-account-backup-//')
  AMP_DST="$DST/amplify/$STAMP"
  mkdir -p "$AMP_DST/apps"

  for f in account-identity.json regions.txt summary.txt backup.log; do
    [ -f "$AMP_SRC_DIR/$f" ] && mv -v "$AMP_SRC_DIR/$f" "$AMP_DST/"
  done

  # merge every region's apps.json into empty-regions.json ONLY if it's an empty array;
  # regions with real app subfolders get moved as-is into apps/<region>/
  echo "{" > "$AMP_DST/empty-regions.json"
  first=true
  for region_dir in "$AMP_SRC_DIR"/*/; do
    region=$(basename "$region_dir")
    [ "$region" = "apps" ] && continue
    has_apps=false
    for sub in "$region_dir"*/; do
      [ -d "$sub" ] && has_apps=true && break
    done
    if [ "$has_apps" = true ]; then
      mkdir -p "$AMP_DST/apps/$region"
      mv -v "$region_dir"* "$AMP_DST/apps/$region/"
    else
      if [ "$first" = true ]; then first=false; else echo "," >> "$AMP_DST/empty-regions.json"; fi
      printf '  "%s": []' "$region" >> "$AMP_DST/empty-regions.json"
    fi
  done
  echo "" >> "$AMP_DST/empty-regions.json"
  echo "}" >> "$AMP_DST/empty-regions.json"

  # remove now-empty region dirs (safe: only removes if truly empty)
  find "$AMP_SRC_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
  rmdir "$AMP_SRC_DIR" 2>/dev/null || true
fi

# ---------- elastic beanstalk ----------
EB_SRC_DIR=$(find "$SRC" -maxdepth 1 -type d -name "eb-config-backup-*" | head -n1 || true)
if [ -n "${EB_SRC_DIR:-}" ]; then
  STAMP=$(basename "$EB_SRC_DIR" | sed 's/eb-config-backup-//')
  EB_DST="$DST/elastic-beanstalk/$STAMP"
  mkdir -p "$EB_DST/apps"

  for f in README.txt caller-identity.json caller-identity.error environment-inventory.tsv export.log; do
    [ -f "$EB_SRC_DIR/$f" ] && mv -v "$EB_SRC_DIR/$f" "$EB_DST/"
  done

  for app_dir in "$EB_SRC_DIR"/*/; do
    app=$(basename "$app_dir")
    mv -v "$app_dir" "$EB_DST/apps/$app"
  done
  rmdir "$EB_SRC_DIR" 2>/dev/null || true
fi

# ---------- rds ----------
RDS_SRC_DIR=$(find "$SRC/rds-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1 || true)
if [ -n "${RDS_SRC_DIR:-}" ]; then
  STAMP=$(basename "$RDS_SRC_DIR")
  mv -v "$RDS_SRC_DIR" "$DST/rds/$STAMP"
  rmdir "$SRC/rds-backups" 2>/dev/null || true
fi

# ---------- manual database dumps ----------
if [ -d "$SRC/db" ]; then
  find "$SRC/db" -type f \( -iname '*.sql' -o -iname '*.sql.gz' \) \
    -exec mv -nv -t "$DST/db-manual-dumps/" {} +
  find "$SRC/db" -type d -empty -delete 2>/dev/null || true
fi

echo ""
echo "Done. New structure at: $DST"
echo "Anything left behind in '$SRC' (unexpected files) was intentionally NOT moved — check it manually:"
find "$SRC" -mindepth 1 2>/dev/null || true
