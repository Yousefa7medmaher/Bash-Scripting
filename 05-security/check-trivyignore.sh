#!/usr/bin/env bash
# check-trivyignore.sh
# بيحاكي "لو مسحت .trivyignore" من غير ما يمسحه فعلاً.
#
# الاستخدام:
#   ./check-trivyignore.sh                      # fs scan على server/ بـ CRITICAL
#   SEVERITY=CRITICAL,HIGH ./check-trivyignore.sh
#   SCAN_DIR=server IMAGE=my-image:tag ./check-trivyignore.sh   # + image scan
#
# Exit code: 0 = آمن تمسح الملف | 1 = الـ pipeline هيفشل

set -uo pipefail

ROOT="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "مش جوه git repo. شغّل السكربت من repository أو عيّن REPO لمساره." >&2
  exit 2
fi
cd "$ROOT"

SCAN_DIR="${SCAN_DIR:-server}"
[ -d "$SCAN_DIR" ] || { echo "SCAN_DIR '$SCAN_DIR' مش موجود في $ROOT" >&2; exit 2; }
SEVERITY="${SEVERITY:-CRITICAL}"
IGNORE_FILE="${IGNORE_FILE:-.trivyignore}"
IMAGE="${IMAGE:-}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok()   { echo "${GRN}✔${RST} $*"; }
bad()  { echo "${RED}✘${RST} $*"; }
warn() { echo "${YLW}!${RST} $*"; }
hdr()  { echo; echo "${BLD}== $* ==${RST}"; }

command -v trivy >/dev/null || { bad "trivy مش متسطّب"; exit 2; }
command -v node  >/dev/null || { bad "node مطلوب لتحليل الـ JSON"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

# ---------------------------------------------------------------
hdr "1) حالة الملف في git"
if [ -f "$IGNORE_FILE" ]; then
  if git ls-files --error-unmatch "$IGNORE_FILE" >/dev/null 2>&1; then
    ok "$IGNORE_FILE متتبّع في git"
    if ! git diff --quiet -- "$IGNORE_FILE"; then
      warn "$IGNORE_FILE عليه تعديلات local (ده سبب فشل git rm). استخدم: git rm -f $IGNORE_FILE"
    fi
  else
    warn "$IGNORE_FILE موجود بس مش متتبّع"
  fi
else
  warn "$IGNORE_FILE مش موجود"
fi

# ---------------------------------------------------------------
hdr "2) أي CI / Dockerfile بيشاور على الملف؟"
if grep -rn "trivyignore" . \
     --include="*.yml" --include="*.yaml" --include="Dockerfile*" \
     --include="*.sh" --include="Makefile" --include="*.json" \
     --exclude-dir=node_modules --exclude-dir=.git --exclude="$(basename "$0")" 2>/dev/null; then
  warn "فيه references فوق، لازم تتعدّل لو هتمسح الملف"
else
  ok "مفيش references صريحة (trivy بيقرأ ./.trivyignore تلقائي من الـ cwd)"
fi
[ -f bitbucket-pipelines.yml ] && { echo "--- سطور trivy في bitbucket-pipelines.yml:"; grep -n "trivy" bitbucket-pipelines.yml || echo "(مفيش)"; }

# ---------------------------------------------------------------
hdr "3) Trivy fs من غير ignore file ($SCAN_DIR, $SEVERITY)"
trivy fs --scanners vuln --severity "$SEVERITY" \
  --ignorefile /dev/null --skip-version-check --quiet \
  --format json --output "$TMP/fs.json" "$SCAN_DIR" 2>"$TMP/fs.err"
if [ ! -s "$TMP/fs.json" ]; then
  bad "الـ scan فشل:"; cat "$TMP/fs.err"; exit 2
fi

node - "$TMP/fs.json" "$IGNORE_FILE" <<'NODE'
const fs = require('fs');
const [,, jsonPath, ignorePath] = process.argv;
const rep = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const found = new Map();
for (const r of rep.Results || [])
  for (const v of r.Vulnerabilities || [])
    found.set(v.VulnerabilityID, `${v.PkgName}@${v.InstalledVersion} (${v.Severity}) fixed=${v.FixedVersion || 'none'} [${r.Target}]`);

console.log(`\nعدد الثغرات الظاهرة بدون ignore: ${found.size}`);
for (const [id, d] of found) console.log(`  - ${id}  ${d}`);

// الـ IDs اللي في .trivyignore
let ignored = [];
if (fs.existsSync(ignorePath)) {
  ignored = fs.readFileSync(ignorePath, 'utf8').split('\n')
    .map(l => l.trim()).filter(l => l && !l.startsWith('#'))
    .map(l => { const [id, ...rest] = l.split(/\s+/); const e = rest.find(x => x.startsWith('exp:')); return { id, exp: e ? e.slice(4) : null }; });
}
console.log('\nمراجعة entries الـ ignore:');
const today = new Date().toISOString().slice(0, 10);
for (const { id, exp } of ignored) {
  const needed = found.has(id);
  const expired = exp && exp < today;
  console.log(`  ${needed ? '[لسه محتاجه]' : '[STALE - امسحه]'} ${id}${exp ? '  exp:' + exp : ''}${expired ? '  (منتهي!)' : ''}`);
}
const covered = new Set(ignored.map(i => i.id));
const uncovered = [...found.keys()].filter(id => !covered.has(id));
if (uncovered.length) console.log('\nثغرات مش مغطّاة بـ ignore أصلاً: ' + uncovered.join(', '));

process.exit(found.size ? 1 : 0);
NODE
RC=$?
if [ $RC -eq 0 ]; then ok "fs scan نضيف، الـ ignore file مش لازم"; else bad "fs scan هيفشل من غير الـ ignore file"; FAIL=1; fi

# ---------------------------------------------------------------
hdr "4) npm audit (critical بس، production deps)"
if [ -f "$SCAN_DIR/package.json" ]; then
  ( cd "$SCAN_DIR" && npm audit --omit=dev --audit-level=critical >"$TMP/audit.txt" 2>&1 ); A=$?
  tail -n 6 "$TMP/audit.txt"
  [ $A -eq 0 ] && ok "npm audit: مفيش critical" || { warn "npm audit لسه بيلاقي critical (مش بالضرورة بيكسر الـ CI لو CI بيستخدم trivy بس)"; }
fi

# ---------------------------------------------------------------
if [ -n "$IMAGE" ]; then
  hdr "5) Trivy image ($IMAGE)"
  if trivy image --scanners vuln --severity "$SEVERITY" --ignorefile /dev/null \
       --skip-version-check --exit-code 1 "$IMAGE"; then
    ok "image نضيف"
  else
    bad "image فيه $SEVERITY"; FAIL=1
  fi
else
  hdr "5) Trivy image"
  warn "اتخطّى. شغّله بـ IMAGE=name:tag (الـ image لازم يكون متبني locally)"
fi

# ---------------------------------------------------------------
hdr "النتيجة"
if [ $FAIL -eq 0 ]; then
  ok "آمن تمسح $IGNORE_FILE: git rm -f $IGNORE_FILE"
else
  bad "لو مسحت $IGNORE_FILE الـ pipeline هيفشل. سيبه (ونضّف الـ entries الـ STALE) لحد ما الثغرات المتبقية تتحل."
fi
exit $FAIL
