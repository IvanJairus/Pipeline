#!/bin/bash
# Push the artifact to an environment, and wait until it is actually live.
#
# Used by deploy:sit, promote:uat and promote:prod in all templates.
#
# Usage:
#   deploy.sh apply   --env sit  --digest sha256:<hex>
#   deploy.sh wait    --env sit  --timeout 300 [--auto-rollback]
#   deploy.sh promote --from uat --to prod [--require-backend]
#   deploy.sh status  --env sit
#   deploy.sh rollback --env sit --to-revision 14
#   deploy.sh --selftest
#
# Environment:
#   DRY_RUN=1            print the command, do not run it
#   NAMESPACE_TEMPLATE   namespace pattern, default "ci-{env}-ledger-service"
#   CHANGE_WINDOW        0 disables the change window (for tests only)
#   RULES_CHECK_CMD      command that checks the promotion rules
#
# Three things that make this file more than `kubectl apply`:
#   1. It reads gate-verdict.json. The button in GitLab is not the permission;
#      the verdict is what grants it, and if the verdict is missing, there is
#      no deploy.
#   2. It does not treat "apply succeeded" as "the service is live". What it
#      waits for is the rollout, and a failure can roll itself back.
#   3. Production has a change window. Outside those hours the command is
#      refused with a readable reason, not a mysterious timeout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

DRY_RUN="${DRY_RUN:-0}"
VERDICT_FILE="${VERDICT_FILE:-gate-verdict.json}"
TEMPLATE="${TEMPLATE:-jenkins/templates/deployment.yaml}"
# Split from ${VAR:-default} because bash runs brace expansion on the default
# value inside a parameter expansion: "ci-{env}-x" comes out as "ci-{envx}".
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

# The verdict is read, not trusted. Three states are deliberately kept apart:
# no file, a file that exists and refuses, and a file that exists and passes.
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

# Change window: Monday through Thursday, 09:00-17:00. Not superstition: these
# are the hours when the people who can reverse a decision are still at their desks.
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
  # The environment ordering rules live in ReleaseRules, not here. All this file
  # does is make sure those rules are actually asked.
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

  # An environment outside the list cannot be named by any means.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env staging --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "reason=bad_env" "stray environment refused"

  # A short digest is refused: it is usually the output of an empty command substitution.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:abc"
  says err.txt "reason=bad_digest" "short digest refused"

  # Without a verdict there is no deploy, even when the button has been pressed.
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "reason=no_verdict" "missing verdict holds the deploy"

  # A refusing verdict: its reason travels all the way into the log line.
  printf '%s\n' '{"passed":false,"failures":["vulnerabilities: 1 critical (allowed 0)"],"plan":[]}' > gate-verdict.json
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "1 critical" "the refusal reason is written along too"

  # A passing verdict: apply runs, and the namespace is filled in.
  printf '%s\n' '{"passed":true,"failures":[],"plan":[{"id":"core-api","tier":1,"action":"redeploy"}]}' > gate-verdict.json
  try env DRY_RUN=1 bash "$SCRIPT_DIR/deploy.sh" apply --env sit --digest "sha256:$(printf 'a%.0s' {1..64})"
  says err.txt "applied env=sit" "a passing verdict does not deploy"
  says err.txt "namespace=ci-sit-ledger-service" "namespace not filled in"
  never_says rendered/sit.yaml "__IMAGE__" "placeholder still raw in the rendered file"

  # The production change window, tested with a turned clock rather than with hope.
  try env DRY_RUN=1 NOW_OVERRIDE=6_22 RULES_CHECK_CMD="true" CHANGE_WINDOW=1 \
    bash "$SCRIPT_DIR/deploy.sh" promote --from uat --to prod
  says err.txt "reason=change_window" "Saturday night was not refused"
  try env DRY_RUN=1 NOW_OVERRIDE=2_10 RULES_CHECK_CMD="true" CHANGE_WINDOW=1 \
    bash "$SCRIPT_DIR/deploy.sh" promote --from uat --to prod
  never_says err.txt "reason=change_window" "Tuesday morning refused as outside the hours"

  # The promotion rules are still asked, and the answer refuses.
  try env DRY_RUN=1 NOW_OVERRIDE=2_10 CHANGE_WINDOW=1 RULES_CHECK_CMD="false" \
    bash "$SCRIPT_DIR/deploy.sh" promote --from prod --to sit
  says err.txt "reason=promotion_refused" "backward promotion accepted"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "deploy selftest: ok" >&2; return 0; fi
  echo "deploy selftest: $fails failures" >&2; return 1
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
