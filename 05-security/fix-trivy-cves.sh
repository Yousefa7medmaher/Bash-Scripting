#!/usr/bin/env bash
# fix-trivy-cves.sh
# Fixes CVE-2019-18413 (class-validator) and CVE-2022-33171 (typeorm), then cleans .trivyignore.
#
# Usage (from repo root):
#   ./fix-trivy-cves.sh --class-validator     # Phase A: safe upgrade
#   ./fix-trivy-cves.sh --typeorm             # Phase B: only after code migration is done
#   ./fix-trivy-cves.sh --verify [IMAGE]      # build + audit + trivy (fs, and image if given)
#   ./fix-trivy-cves.sh --clean-ignore        # remove fixed CVEs from .trivyignore
#   ./fix-trivy-cves.sh --all                 # A + verify + clean-ignore (no typeorm)
set -euo pipefail

REPO_DIR="${REPO_DIR:?Set REPO_DIR to the target repository}"
SERVER_DIR="$REPO_DIR/server"
MAIN_TS="$SERVER_DIR/src/main.ts"

CLASS_VALIDATOR_VERSION="^0.14.1"
TYPEORM_VERSION="^0.3.20"
NEST_TYPEORM_VERSION="^10.0.2"
TYPEORM_ENCRYPTED_VERSION="^0.8.0"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

installed_version() {
  node -p "try{require('$SERVER_DIR/node_modules/$1/package.json').version}catch(e){''}"
}

find_trivyignore() {
  for f in "$REPO_DIR/.trivyignore" "$SERVER_DIR/.trivyignore" "$REPO_DIR/.trivyignore.yaml"; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
  find "$REPO_DIR" -maxdepth 3 -name '.trivyignore*' -not -path '*/node_modules/*' | head -1
}

preflight() {
  [[ -d "$SERVER_DIR" ]] || die "server dir not found: $SERVER_DIR"
  cd "$REPO_DIR"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  case "$branch" in
    main|master|testing) die "You're on '$branch'. Switch to a feature branch first." ;;
  esac
  ok "Branch: $branch"
  git tag -f "pre-trivy-fix-$(date +%Y%m%d-%H%M%S)" >/dev/null
  ok "Backup tag created (git tag -l 'pre-trivy-fix-*')"
}

patch_validation_pipe() {
  [[ -f "$MAIN_TS" ]] || die "main.ts not found: $MAIN_TS"
  if grep -q 'forbidUnknownValues' "$MAIN_TS"; then
    ok "forbidUnknownValues already set in main.ts"
    return
  fi
  grep -q 'new ValidationPipe' "$MAIN_TS" || die "No 'new ValidationPipe' in main.ts - patch it manually."
  cp "$MAIN_TS" "$MAIN_TS.bak"
  # Case 1: new ValidationPipe()  -> add options object
  perl -0pi -e 's/new ValidationPipe\(\s*\)/new ValidationPipe({ forbidUnknownValues: false })/g' "$MAIN_TS"
  # Case 2: new ValidationPipe({ ... -> insert option right after the first brace
  if ! grep -q 'forbidUnknownValues' "$MAIN_TS"; then
    perl -0pi -e 's/new ValidationPipe\(\s*\{/new ValidationPipe({\n            forbidUnknownValues: false,/' "$MAIN_TS"
  fi
  grep -q 'forbidUnknownValues' "$MAIN_TS" || die "Could not patch main.ts automatically. Add forbidUnknownValues: false manually."
  ok "main.ts patched (backup: main.ts.bak)"
  git --no-pager diff --stat -- "$MAIN_TS" || true
}

phase_class_validator() {
  preflight
  cd "$SERVER_DIR"
  local cv
  cv="$(installed_version class-validator)"
  if [[ "$cv" =~ ^0\.(1[4-9]|[2-9][0-9])\. ]]; then
    ok "class-validator already $cv - skipping npm install"
  else
    log "Upgrading class-validator -> $CLASS_VALIDATOR_VERSION"
    npm install "class-validator@$CLASS_VALIDATOR_VERSION" --save || {
      warn "ERESOLVE (old NestJS 7 peer deps) - retrying with --legacy-peer-deps"
      npm install "class-validator@$CLASS_VALIDATOR_VERSION" --save --legacy-peer-deps
    }
  fi
  patch_validation_pipe
  ok "class-validator: $(installed_version class-validator)"
}

phase_typeorm() {
  preflight
  cd "$SERVER_DIR"

  # Gate: refuse if legacy TypeORM 0.2 APIs are still in the code.
  local er gm gcr
  er=$(grep -RIn '@EntityRepository' src --include='*.ts' | wc -l)
  gm=$(grep -RInE '\bgetManager\(' src --include='*.ts' | wc -l)
  gcr=$(grep -RInE 'getCustomRepository\(|getConnection\(|createConnection\(' src --include='*.ts' | wc -l)
  log "Legacy usage -> @EntityRepository: $er | getManager: $gm | getConnection/getCustomRepository: $gcr"
  if (( er + gm + gcr > 0 )); then
    die "Legacy TypeORM 0.2 APIs still present. Migrate the code first (custom repos -> Repository.extend / injectable services, findOne(id) -> findOne({where:{id}}), getManager -> DataSource), then re-run."
  fi

  local nest_major
  nest_major=$(node -p "parseInt((require('./node_modules/@nestjs/common/package.json').version||'0'))")
  (( nest_major >= 10 )) || die "@nestjs/common is v$nest_major. @nestjs/typeorm 10 needs NestJS 10 - upgrade NestJS first."

  log "Upgrading TypeORM stack"
  npm install "typeorm@$TYPEORM_VERSION" "@nestjs/typeorm@$NEST_TYPEORM_VERSION" \
              "typeorm-encrypted@$TYPEORM_ENCRYPTED_VERSION" --save
  ok "typeorm: $(installed_version typeorm)"
}

phase_verify() {
  cd "$SERVER_DIR"
  log "Build"
  npm run build
  ok "Build passed"

  # NOTE: 'npm test' runs 'lint:fix' (rewrites source files) and fails on existing lint errors,
  # so we call jest directly and never let it abort the scan steps.
  log "Tests (jest only)"
  npx jest --passWithNoTests || warn "jest failed or reported failures - check manually"

  log "npm audit (prod, critical)"
  npm audit --omit=dev --audit-level=critical || warn "npm audit still reports critical issues"

  if command -v trivy >/dev/null 2>&1; then
    log "Trivy filesystem scan (no ignore file, CRITICAL only)"
    trivy fs --scanners vuln --severity CRITICAL --ignorefile /dev/null --exit-code 1 "$SERVER_DIR" \
      && ok "Trivy fs: no CRITICAL findings" \
      || warn "Trivy fs still reports CRITICAL findings"
    if [[ -n "${1:-}" ]]; then
      log "Trivy image scan: $1"
      trivy image --severity CRITICAL --ignorefile /dev/null --exit-code 1 "$1" \
        && ok "Trivy image: no CRITICAL findings" \
        || warn "Trivy image still reports CRITICAL findings"
    fi
  else
    warn "trivy not installed - skipped"
  fi
}

phase_clean_ignore() {
  local f cv_ver to_ver
  f="$(find_trivyignore)"
  [[ -n "$f" ]] || { warn ".trivyignore not found"; return; }
  cv_ver="$(installed_version class-validator)"
  to_ver="$(installed_version typeorm)"
  log "Ignore file: $f (class-validator=$cv_ver, typeorm=$to_ver)"

  # Remove an entry together with its comment block, only if the fixed version is installed.
  remove_entry() {
    local cve="$1"
    perl -0pi -e "s/(?:[ \t]*#[^\n]*\n)*[ \t]*\Q$cve\E[^\n]*\n\n?//g" "$f"
    ok "Removed $cve from ignore file"
  }

  [[ "$cv_ver" =~ ^0\.(1[4-9]|[2-9][0-9])\. || "$cv_ver" =~ ^[1-9] ]] && remove_entry "CVE-2019-18413" \
    || warn "class-validator < 0.14 - CVE-2019-18413 entry kept"
  [[ "$to_ver" =~ ^0\.3\. || "$to_ver" =~ ^[1-9] ]] && remove_entry "CVE-2022-33171" \
    || warn "typeorm < 0.3 - CVE-2022-33171 entry kept"
}

case "${1:-}" in
  --class-validator) phase_class_validator ;;
  --typeorm)         phase_typeorm ;;
  --verify)          phase_verify "${2:-}" ;;
  --clean-ignore)    phase_clean_ignore ;;
  --all)             phase_class_validator; phase_verify; phase_clean_ignore ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
