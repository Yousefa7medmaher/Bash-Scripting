#!/usr/bin/env bash
# Safe dependency migration helper for a Node.js backend.
# It intentionally refuses to upgrade TypeORM until legacy TypeORM APIs are migrated.
# Usage (from any directory inside the repository):
#   bash dependency-migration-preflight.sh --preflight
#   bash dependency-migration-preflight.sh --apply
#   bash dependency-migration-preflight.sh --validate

set -Eeuo pipefail

MODE="${1:---preflight}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[PASS]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }
die()  { fail "$*"; exit 1; }

command -v git >/dev/null 2>&1 || die "Git is required."
command -v node >/dev/null 2>&1 || die "Node.js is required."
command -v npm >/dev/null 2>&1 || die "npm is required."

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this script from inside the Eldawlia Git repository."
SERVER_DIR="$REPO_ROOT/server"
[[ -f "$SERVER_DIR/package.json" ]] || die "Could not find server/package.json under $REPO_ROOT"
cd "$SERVER_DIR"

BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
NODE_VERSION="$(node -v)"
NPM_VERSION="$(npm -v)"

count_matches() {
  local pattern="$1"
  local result
  result="$( (grep -RInE "$pattern" src --include='*.ts' 2>/dev/null || true) | wc -l | tr -d ' ')"
  printf '%s' "$result"
}

count_findone_calls() {
  node <<'NODE'
const fs = require('fs');
const path = require('path');
const ts = require('typescript');
const root = path.resolve('src');
let total = 0;
let risky = 0;
const findings = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && entry.name.endsWith('.ts')) {
      const sourceText = fs.readFileSync(full, 'utf8');
      const sf = ts.createSourceFile(full, sourceText, ts.ScriptTarget.Latest, true);
      function visit(node) {
        if (ts.isCallExpression(node)) {
          const expr = node.expression;
          const method = ts.isPropertyAccessExpression(expr) ? expr.name.text :
                         ts.isElementAccessExpression(expr) && expr.argumentExpression && ts.isStringLiteral(expr.argumentExpression)
                           ? expr.argumentExpression.text : '';
          if (method === 'findOne') {
            total++;
            const first = node.arguments[0];
            // TypeORM 0.3 expects FindOneOptions. A two-argument call, or a scalar
            // literal first argument, is a definite legacy-style call. An identifier
            // argument is ambiguous (it may be an options variable), so report it
            // for human review rather than rewriting it automatically.
            const definiteLegacy = node.arguments.length > 1 ||
              (first && (ts.isStringLiteral(first) || ts.isNumericLiteral(first)));
            const ambiguous = first && ts.isIdentifier(first);
            if (definiteLegacy || ambiguous) {
              risky++;
              const pos = sf.getLineAndCharacterOfPosition(node.getStart(sf));
              const reason = definiteLegacy ? 'legacy-signature-candidate' : 'review-identifier-argument';
              findings.push(`${full}:${pos.line + 1}: ${reason}: ${node.getText(sf).replace(/\s+/g, ' ').slice(0, 180)}`);
            }
          }
        }
        ts.forEachChild(node, visit);
      }
      visit(sf);
    }
  }
}
if (fs.existsSync(root)) walk(root);
console.log(`FINDONE_TOTAL=${total}`);
console.log(`FINDONE_REVIEW=${risky}`);
for (const item of findings.slice(0, 100)) console.log(item);
if (findings.length > 100) console.log(`... ${findings.length - 100} additional candidates omitted`);
NODE
}

preflight() {
  log "Repository: $REPO_ROOT"
  log "Backend: $SERVER_DIR"
  log "Branch: $BRANCH"
  log "Runtime: Node $NODE_VERSION / npm $NPM_VERSION"

  [[ "$BRANCH" != "testing" && "$BRANCH" != "main" && "$BRANCH" != "master" ]] \
    || die "Refusing to work on protected branch '$BRANCH'. Create/use a migration branch first."
  ok "Not on testing/main/master branch."

  local entity_repo manager_calls connection_calls get_custom_repo findone_output entity_count
  entity_repo="$(count_matches '@EntityRepository')"
  manager_calls="$(count_matches 'getManager\s*\(')"
  connection_calls="$(count_matches 'getConnection\s*\(|createConnection\s*\(')"
  get_custom_repo="$(count_matches 'getCustomRepository\s*\(')"

  log "Legacy TypeORM inventory:"
  printf "  @EntityRepository decorators: %s\n" "$entity_repo"
  printf "  getManager() calls:          %s\n" "$manager_calls"
  printf "  getConnection/createConnection calls: %s\n" "$connection_calls"
  printf "  getCustomRepository() calls: %s\n" "$get_custom_repo"

  findone_output="$(count_findone_calls)"
  printf '%s\n' "$findone_output"

  if [[ -d node_modules ]]; then
    ok "server/node_modules exists."
  else
    warn "server/node_modules is missing; dependency validation cannot run yet."
  fi

  if git -C "$REPO_ROOT" diff --quiet -- server/package.json server/package-lock.json; then
    warn "No current dependency manifest changes detected."
  else
    warn "package.json/package-lock.json already contain local changes; this script will preserve them and back them up before --apply."
  fi

  if (( entity_repo > 0 || manager_calls > 0 || connection_calls > 0 || get_custom_repo > 0 )); then
    warn "TypeORM 0.2 APIs still exist. Do NOT install TypeORM 0.3 yet."
    warn "These APIs need a source-code migration; a shell/regex rewrite would risk changing repository behavior."
  else
    ok "No obvious removed TypeORM 0.2 repository/manager APIs detected."
  fi

  if grep -q 'FINDONE_REVIEW=' <<<"$findone_output"; then
    local review_count
    review_count="$(awk -F= '/^FINDONE_REVIEW=/{print $2}' <<<"$findone_output")"
    if [[ "${review_count:-0}" -gt 0 ]]; then
      warn "$review_count findOne calls need a human signature review before TypeORM 0.3."
    fi
  fi

  log "Preflight complete. No files were modified."
}

validate() {
  local failures=0
  log "Validating backend without running DB migrations or changing source files."

  log "1/6 Dependency tree (target packages)"
  if npm ls @nestjs/common @nestjs/core @nestjs/platform-express @nestjs/testing \
      @nestjs/swagger @nestjs/typeorm @nestjs/serve-static @nestjs/axios \
      @nestjs/jwt @nestjs/passport @nestjs/schedule class-validator \
      class-transformer typeorm rxjs; then
    ok "npm dependency tree is valid for the listed packages."
  else
    fail "npm dependency tree has invalid/missing packages."
    failures=$((failures + 1))
  fi

  log "2/6 TypeScript compilation"
  if ./node_modules/.bin/tsc --noEmit -p tsconfig.build.json; then
    ok "TypeScript compilation passed."
  else
    fail "TypeScript compilation failed."
    failures=$((failures + 1))
  fi

  log "3/6 Jest (direct invocation; does not run lint:fix)"
  if ./node_modules/.bin/jest --runInBand --coverage=false; then
    ok "Jest passed."
  else
    fail "Jest failed. Review test output and compatibility warnings."
    failures=$((failures + 1))
  fi

  log "4/6 ESLint"
  if npm run lint; then
    ok "ESLint passed."
  else
    fail "ESLint failed. Existing repo currently has many formatting/rule violations; this is reported separately and is not auto-fixed."
    failures=$((failures + 1))
  fi

  log "5/6 Production dependency audit"
  if npm audit --omit=dev; then
    ok "npm audit --omit=dev reported no production dependency advisories."
  else
    fail "npm audit --omit=dev reported advisories or could not complete. Review npm audit output."
    failures=$((failures + 1))
  fi

  log "6/6 Final working tree"
  git -C "$REPO_ROOT" status --short

  if (( failures > 0 )); then
    fail "Validation finished with $failures failing check(s). Do not deploy or mark the security findings resolved."
    return 1
  fi
  ok "All configured validations passed. This still does not replace a real application/DB integration test or container image scan."
}

apply_dependencies() {
  local entity_repo manager_calls connection_calls get_custom_repo findone_output review_count
  entity_repo="$(count_matches '@EntityRepository')"
  manager_calls="$(count_matches 'getManager\s*\(')"
  connection_calls="$(count_matches 'getConnection\s*\(|createConnection\s*\(')"
  get_custom_repo="$(count_matches 'getCustomRepository\s*\(')"
  findone_output="$(count_findone_calls)"
  review_count="$(awk -F= '/^FINDONE_REVIEW=/{print $2}' <<<"$findone_output")"

  [[ "$BRANCH" != "testing" && "$BRANCH" != "main" && "$BRANCH" != "master" ]] \
    || die "Refusing to modify protected branch '$BRANCH'."

  [[ "${CONFIRM_NEST10_FINAL_STAGE:-}" == "YES" ]] \
    || die "Before --apply, complete/review NestJS 7->8->9->10 migration guides and source changes. Then rerun with CONFIRM_NEST10_FINAL_STAGE=YES."

  if (( entity_repo > 0 || manager_calls > 0 || connection_calls > 0 || get_custom_repo > 0 || ${review_count:-0} > 0 )); then
    fail "Refusing to install TypeORM 0.3 while legacy ORM code remains."
    printf '%s\n' "$findone_output"
    printf '\nDetected: @EntityRepository=%s, getManager=%s, getConnection/createConnection=%s, getCustomRepository=%s, findOne candidates=%s\n' \
      "$entity_repo" "$manager_calls" "$connection_calls" "$get_custom_repo" "${review_count:-0}"
    cat <<'MSG'
Migrate these source APIs first, then rerun this script with --apply.
This script will NOT guess custom repository behavior or rewrite findOne() calls.
MSG
    return 2
  fi

  log "Checking typeorm-encrypted@0.8.0 peer compatibility..."
  local encrypted_peers
  encrypted_peers="$(npm view typeorm-encrypted@0.8.0 peerDependencies --json 2>/dev/null || true)"
  [[ -n "$encrypted_peers" ]] || die "Could not read typeorm-encrypted@0.8.0 peerDependencies."
  printf '%s\n' "$encrypted_peers"
  grep -Eq '"typeorm"[[:space:]]*:[[:space:]]*"\^0\.3([.]|"|$)' <<<"$encrypted_peers" \
    || die "typeorm-encrypted@0.8.0 did not declare the expected TypeORM 0.3 peer range. Stop and choose a verified compatible encryption library/version."

  local backup_dir
  backup_dir="$REPO_ROOT/.migration-backups/dependency-migration-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp package.json "$backup_dir/package.json"
  [[ ! -f package-lock.json ]] || cp package-lock.json "$backup_dir/package-lock.json"
  log "Backed up backend manifests to $backup_dir"

  cat <<'MSG'
Installing the conservative bridge target:
- NestJS 10.4.19 package family
- Swagger 7.4.2 / TypeORM adapter 10.0.2
- class-validator 0.14.4 / class-transformer 0.5.1
- TypeORM 0.3.31 / RxJS 7.8.1
- typeorm-encrypted 0.8.0 (only after peer check)

npm is intentionally run WITHOUT --force or --legacy-peer-deps.
MSG

  npm install --save-exact \
    @nestjs/common@10.4.19 \
    @nestjs/core@10.4.19 \
    @nestjs/platform-express@10.4.19 \
    @nestjs/swagger@7.4.2 \
    @nestjs/typeorm@10.0.2 \
    @nestjs/serve-static@4.0.2 \
    @nestjs/axios@3.0.3 \
    @nestjs/jwt@10.2.0 \
    @nestjs/passport@10.0.3 \
    @nestjs/schedule@4.0.0 \
    class-validator@0.14.4 \
    class-transformer@0.5.1 \
    typeorm@0.3.31 \
    typeorm-encrypted@0.8.0 \
    rxjs@7.8.1

  npm install --save-dev --save-exact @nestjs/testing@10.4.19

  log "Dependency installation finished. Running validation..."
  validate
}

case "$MODE" in
  --preflight)
    preflight
    ;;
  --validate)
    validate
    ;;
  --apply)
    preflight
    apply_dependencies
    ;;
  *)
    cat <<USAGE
Usage:
  bash $0 --preflight   # read-only inventory; default
  bash $0 --apply       # install target packages only after TypeORM source migration is complete
  bash $0 --validate    # dependency tree, TypeScript, Jest, ESLint, and production npm audit

Safety:
  - Does not rewrite TypeORM source code.
  - Does not run database migrations or connect to a database.
  - Does not use npm --force or --legacy-peer-deps.
  - Refuses TypeORM 0.3 install while old repository APIs/findOne signatures remain.
USAGE
    exit 2
    ;;
esac
