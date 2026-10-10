#!/bin/bash
# Menaikkan artefak ke sebuah environment, dan menunggu sampai benar-benar hidup.
#
# Dipakai oleh deploy:sit, promote:uat dan promote:prod di semua template.
#
# Pemakaian:
#   deploy.sh apply   --env sit  --digest sha256:<hex>
#   deploy.sh wait    --env sit  --timeout 300 [--auto-rollback]
#   deploy.sh promote --from uat --to prod [--require-backend]
#   deploy.sh status  --env sit
#   deploy.sh rollback --env sit --to-revision 14
#   deploy.sh --selftest
#
# Environment:
#   DRY_RUN=1            cetak perintah, jangan jalankan
#   NAMESPACE_TEMPLATE   pola namespace, default "ci-{env}-ledger-service"
#   CHANGE_WINDOW        0 untuk mematikan jendela perubahan (hanya untuk uji)
#   RULES_CHECK_CMD      perintah pemeriksa aturan promotion
#
# Tiga hal yang membuat file ini bukan sekadar `kubectl apply`:
#   1. Ia membaca gate-verdict.json. Tombol di GitLab bukan hak; yang memberi
#      hak adalah verdict, dan kalau verdict-nya tidak ada, tidak ada deploy.
#   2. Ia tidak menganggap "apply sukses" sama dengan "layanan hidup". Yang
#      ditunggu adalah rollout, dan kegagalannya bisa memutar balik sendiri.
#   3. Produksi punya jendela perubahan. Di luar jam itu, perintahnya ditolak
#      dengan alasan yang bisa dibaca, bukan dengan timeout yang misterius.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

DRY_RUN="${DRY_RUN:-0}"
VERDICT_FILE="${VERDICT_FILE:-gate-verdict.json}"
TEMPLATE="${TEMPLATE:-jenkins/templates/deployment.yaml}"
# Dipisah dari ${VAR:-default} karena bash melakukan brace expansion pada nilai
# default di dalam ekspansi parameter: "ci-{env}-x" keluar sebagai "ci-{envx}".
if [ -z "${NAMESPACE_TEMPLATE:-}" ]; then NAMESPACE_TEMPLATE='ci-{env}-ledger-service'; fi
CHANGE_WINDOW="${CHANGE_WINDOW:-1}"
RULES_CHECK_CMD="${RULES_CHECK_CMD:-groovy -cp shared-library/src ci-library/scripts/run-gate.groovy --promote}"
KUBECTL="${KUBECTL:-kubectl}"

ENVS="sit uat prod"

die() { log_fail "$1" "${@:2}"; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then log INFO "would run $*"; return 0; fi
  log DEBUG "exec $*"
  "$@"
}

need_env() {
  local env="$1"
  [ -n "$env" ] || die no_env "usage=deploy.sh\ apply\ --env\ <sit|uat|prod>"
  case " $ENVS " in *" $env "*) log DEBUG "env allowed=$env" ;; *) die bad_env "value=$env allowed=$ENVS" ;; esac
}

namespace_for() { printf '%s' "${NAMESPACE_TEMPLATE//\{env\}/$1}"; }

require_digest() {
  local d="$1"
  [ -n "$d" ] || die no_digest "reason=missing a deploy without a digest cannot be repeated"
  case "$d" in
    sha256:*) [ "${#d}" -eq 71 ] || die bad_digest "length=${#d} expected=71" ;;
    *) die bad_digest "value=$d expected=sha256:<64 hex>" ;;
  esac
}

# Verdict dibaca, bukan dipercaya. Tiga keadaan dibedakan dengan sengaja:
# tidak ada berkas, berkas ada tapi menolak, dan berkas ada dan lulus.
verdict_allows() {
  local env="$1"
  [ -f "$VERDICT_FILE" ] || die no_verdict "file=$VERDICT_FILE refusing to deploy to $env with no decision on disk"
  if ! python3 - "$VERDICT_FILE" "$env" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if not doc.get("passed"):
    print("; ".join(doc.get("failures") or ["gate did not pass"]))
    sys.exit(1)
sys.exit(0)
PY
  then
    local why
    why="$(python3 -c 'import json,sys;print("; ".join(json.load(open(sys.argv[1],encoding="utf-8")).get("failures") or ["gate did not pass"]))' "$VERDICT_FILE")"
    die gate_refused "env=$env reason=$why"
  fi
  log INFO "verdict checked file=$VERDICT_FILE env=$env allowed=true"
}

# Jendela perubahan: Senin sampai Kamis, 09.00-17.00. Bukan takhayul - ini jam
# di mana orang yang bisa membalikkan sebuah keputusan masih ada di kursinya.
window_open() {
  local now="${1:-$(date +%u_%H)}"
  local day hour
  day="${now%_*}"; hour="${now#*_}"
  [ "$CHANGE_WINDOW" = "0" ] && return 0
  [ "$day" -le 4 ] || return 1
  [ "$hour" -ge 9 ] && [ "$hour" -lt 17 ]
}

render() {
  local env="$1" digest="$2" out="$3"
  [ -f "$TEMPLATE" ] || die no_template "file=$TEMPLATE"
  sed -e "s|__ENV__|$env|g" -e "s|__NAMESPACE__|$(namespace_for "$env")|g" -e "s|__DIGEST__|$digest|g" \
      -e "s|__IMAGE__|${REGISTRY:-registry.example.internal/platform}/$CI_PROJECT_NAME|g" \
      "$TEMPLATE" > "$out"
  log INFO "rendered template=$TEMPLATE out=$out env=$env namespace=$(namespace_for "$env")"
}

cmd_apply() {
  local env="" digest=""
  while [ $# -gt 0 ]; do case "$1" in
    --env) env="$2"; shift 2;; --digest) digest="$2"; shift 2;; *) die bad_arg "arg=$1";; esac; done
  need_env "$env"; require_digest "$digest"
  verdict_allows "$env"
  mkdir -p rendered
  render "$env" "$digest" "rendered/$env.yaml"
  run "$KUBECTL" -n "$(namespace_for "$env")" apply --server-side -f "rendered/$env.yaml"
  log INFO "applied env=$env digest=${digest:7:12} namespace=$(namespace_for "$env")"
}

cmd_wait() {
  local env="" timeout=300 auto=0
  while [ $# -gt 0 ]; do case "$1" in
    --env) env="$2"; shift 2;; --timeout) timeout="$2"; shift 2;; --auto-rollback) auto=1; shift;; *) die bad_arg "arg=$1";; esac; done
  need_env "$env"
  if run "$KUBECTL" -n "$(namespace_for "$env")" rollout status deployment/"$CI_PROJECT_NAME" --timeout="${timeout}s"; then
    log INFO "ready env=$env timeout=${timeout}s"
    return 0
  fi
  log_error "failed reason=rollout_timeout env=$env timeout=${timeout}s"
  if [ "$auto" = "1" ]; then
    log_warn "rollback env=$env trigger=auto"
    cmd_rollback --env "$env"
  fi
  return 1
}

cmd_promote() {
  local from="" to="" require_backend=0
  while [ $# -gt 0 ]; do case "$1" in
    --from) from="$2"; shift 2;; --to) to="$2"; shift 2;; --require-backend) require_backend=1; shift;; *) die bad_arg "arg=$1";; esac; done
  need_env "$from"; need_env "$to"
  if [ "$to" = "prod" ] && ! window_open "${NOW_OVERRIDE:-$(date +%u_%H)}"; then
    die change_window "to=prod outside=window-mon-thu-09-17 escape=CHANGE_WINDOW-0-only-for-tests"
  fi
  # Aturan urutan environment hidup di ReleaseRules, bukan di sini. Yang di sini
  # hanya memastikan aturan itu benar-benar ditanyakan.
  if ! $RULES_CHECK_CMD "$from:$to" > /dev/null 2>&1; then
    die promotion_refused "from=$from to=$to source=ReleaseRules.validatePromotion"
  fi
  if [ "$require_backend" = "1" ]; then
    python3 - "$VERDICT_FILE" <<'PY' || die wave_order "reason=web_before_backend fix=deploy\ the\ backend\ tier\ first"
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
plan = doc.get("plan") or []
tiers = [p.get("tier") for p in plan]
sys.exit(0 if tiers and min(tiers) <= 1 else 1)
PY
    log INFO "wave checked require_backend=true plan=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["plan"]))' "$VERDICT_FILE")"
  fi
  local digest
  digest="$(cat image-digest.txt 2>/dev/null || true)"
  require_digest "$digest"
  log INFO "promote from=$from to=$to"
  cmd_apply --env "$to" --digest "$digest"
  cmd_wait --env "$to" --timeout 420
}

cmd_status() {
  local env=""
  while [ $# -gt 0 ]; do case "$1" in --env) env="$2"; shift 2;; *) die bad_arg "arg=$1";; esac; done
  need_env "$env"
  run "$KUBECTL" -n "$(namespace_for "$env")" get deployment "$CI_PROJECT_NAME" -o wide
}

cmd_rollback() {
  local env="" rev=""
  while [ $# -gt 0 ]; do case "$1" in
    --env) env="$2"; shift 2;; --to-revision) rev="$2"; shift 2;; *) die bad_arg "arg=$1";; esac; done
  need_env "$env"
  if [ -n "$rev" ]; then
    log_warn "rollback env=$env toRevision=$rev"
    run "$KUBECTL" -n "$(namespace_for "$env")" rollout undo deployment/"$CI_PROJECT_NAME" --to-revision="$rev"
  else
    log_warn "rollback env=$env toRevision=previous"
    run "$KUBECTL" -n "$(namespace_for "$env")" rollout undo deployment/"$CI_PROJECT_NAME"
  fi
}

selftest() {
  local fails=0 tmp
  says()      { grep -q "$2" "$1" || { echo "deploy selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  never_says(){ if grep -q "$2" "$1"; then echo "deploy selftest FAIL $3" >&2; fails=$((fails+1)); fi; return 0; }
  try()       { "$@" >out.txt 2>err.txt || true; }

  tmp="$(mktemp -d)"; cd "$tmp"
  mkdir -p jenkins/templates shared-library/src
  printf '%s\n' 'metadata: { name: __IMAGE__ }' 'spec:' '  template: { metadata: { annotations: { digest: "__DIGEST__" } } }' > jenkins/templates/deployment.yaml
  export CI_PROJECT_NAME=core-api

  # Environment di luar daftar tidak bisa disebut dengan cara apa pun.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env staging --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "reason=bad_env" "environment liar tertolak"

  # Digest pendek ditolak: itu biasanya hasil dari command substitution yang kosong.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:abc"
  says err.txt "reason=bad_digest" "digest pendek tertolak"

  # Tanpa verdict, tidak ada deploy - walaupun tombolnya sudah ditekan.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "reason=no_verdict" "verdict hilang menahan deploy"

  # Verdict menolak: alasannya ikut terbawa sampai baris log.
  printf '%s\n' '{"passed":false,"failures":["vulnerabilities: 1 critical (allowed 0)"],"plan":[]}' > gate-verdict.json
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "1 critical" "alasan penolakan ikut tertulis"

  # Verdict lulus: apply jalan, namespace ikut terisi.
  printf '%s\n' '{"passed":true,"failures":[],"plan":[{"id":"core-api","tier":1,"action":"redeploy"}]}' > gate-verdict.json
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "applied env=sit" "verdict lulus tidak menaikkan deploy"
  says err.txt "namespace=ci-sit-ledger-service" "namespace tidak terisi"
  never_says rendered/sit.yaml "__IMAGE__" "placeholder masih mentah di berkas hasil render"

  # Jendela perubahan produksi, diuji dengan jam yang diputar, bukan dengan harapan.
  try env DRY_RUN=1 NOW_OVERRIDE=6_22 RULES_CHECK_CMD="true" CHANGE_WINDOW=1 \
    bash "$SCRIPT_DIR/deploy.sh" promote --from uat --to prod
  says err.txt "reason=change_window" "Sabtu malam tidak ditolak"
  try env DRY_RUN=1 NOW_OVERRIDE=2_10 RULES_CHECK_CMD="true" CHANGE_WINDOW=1 \
    bash "$SCRIPT_DIR/deploy.sh" promote --from uat --to prod
  never_says err.txt "reason=change_window" "Selasa pagi ditolak sebagai di luar jam"

  # Aturan promotion tetap ditanyakan, dan jawabannya yang menolak.
  try env DRY_RUN=1 NOW_OVERRIDE=2_10 CHANGE_WINDOW=1 RULES_CHECK_CMD="false" \
    bash "$SCRIPT_DIR/deploy.sh" promote --from prod --to sit
  says err.txt "reason=promotion_refused" "promotion mundur diterima"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "deploy selftest: ok" >&2; return 0; fi
  echo "deploy selftest: $fails kegagalan" >&2; return 1
}

main() {
  local cmd="${1:-}"; shift || true
  log_init "${CI_JOB_NAME:-deploy}"
  case "$cmd" in
    apply)    cmd_apply "$@" ;;
    wait)     cmd_wait "$@" ;;
    promote)  cmd_promote "$@" ;;
    status)   cmd_status "$@" ;;
    rollback) cmd_rollback "$@" ;;
    --selftest|selftest) selftest ;;
    *) printf 'usage: deploy.sh apply|wait|promote|status|rollback | --selftest\n' >&2; exit 2 ;;
  esac
}

main "$@"
