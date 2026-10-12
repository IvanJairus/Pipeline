#!/bin/bash
# Push one pipeline's results to the metrics aggregator, and write one audit line.
#
# Called by the feedback:observability job (when: always) and by the deploy
# after_script in the platform template.
#
# Usage:
#   observability-push.sh pipeline
#   observability-push.sh deploy --env sit --seconds 93
#   observability-push.sh --selftest
#
# Environment:
#   PUSHGATEWAY_URL   POST destination; empty means write the file only
#   METRICS_FILE      default metrics.prom
#   DRY_RUN=1         do not send, just print
#
# Two rules keep the data in this file trustworthy:
#
#   1. No invented numbers. A duration is written only when GitLab actually sent
#      one (CI_PIPELINE_DURATION_SECONDS). When it did not, the metric does not
#      exist: not 0, because 0 means "instant", and anyone with a dashboard
#      reads that as good news.
#   2. A missing verdict is not a pass. release_passed is written only when
#      gate-verdict.json really exists; otherwise there is no number at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

VERDICT_FILE="${VERDICT_FILE:-gate-verdict.json}"
BUILD_INFO="${BUILD_INFO:-build-info.json}"
METRICS_FILE="${METRICS_FILE:-metrics.prom}"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"
DRY_RUN="${DRY_RUN:-0}"

die() { log_fail "$1" "${@:2}"; exit 1; }

# Every metric line is named as it is written: the value alone is not traceable
# to the sample, so the name and the labels go into the log next to it.
metric() {
  local series="$1" value="$2" name labels
  printf '%s %s\n' "$series" "$value" >> "$METRICS_FILE"
  name="${series%%\{*}"
  case "$series" in
    *\{*) labels="${series#*\{}"; labels="${labels%\}}" ;;
    *) labels="none" ;;
  esac
  log INFO "metric name=$name labels=${labels:-none} value=$value"
}

# The number of series actually on disk, counted from the file rather than from
# a counter that could be incremented without writing.
metric_count() { printf '%s' "$(( $(wc -l < "$METRICS_FILE" 2>/dev/null || echo 0) ))"; }

push() {
  if [ -z "$PUSHGATEWAY_URL" ]; then
    log_warn "skipped reason=no_pushgateway_url file=$METRICS_FILE metrics=$(metric_count)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log INFO "would push url=$PUSHGATEWAY_URL file=$METRICS_FILE"; return 0; fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --data-binary "@$METRICS_FILE" "$PUSHGATEWAY_URL/metrics/job/gateway" || echo 000)"
  case "$code" in
    2*) log INFO "pushed url=$PUSHGATEWAY_URL status=$code" ;;
    *)  log_error "failed reason=pushgateway status=$code url=$PUSHGATEWAY_URL" ;;
  esac
  return 0
}

cmd_pipeline() {
  : > "$METRICS_FILE"
  local project="${CI_PROJECT_NAME:-unknown}" version="none" passed=""
  [ -f "$BUILD_INFO" ] && version="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("version","none"))' "$BUILD_INFO" 2>/dev/null || echo none)"

  if [ ! -f "$VERDICT_FILE" ]; then
    # Deliberately not writing release_passed=0: that would look like "the gate
    # refused", when in fact there was no decision to read.
    log_error "failed reason=no_verdict file=$VERDICT_FILE metrics_written=0"
    die no_verdict "file=$VERDICT_FILE nothing can be reported about a decision that was never made"
  fi
  passed="$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1],encoding="utf-8")).get("passed") else 0)' "$VERDICT_FILE")"

  metric "gateway_release_passed{project=\"$project\",version=\"$version\"}" "$passed"
  # What is counted here is the number of reasons, not the number of findings:
  # the raw findings already live in the scan artifact, and copying them into a
  # metric would only produce two numbers that can disagree.
  local failures
  failures="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8")).get("failures") or []))' "$VERDICT_FILE")"
  metric "gateway_gate_failures{project=\"$project\"}" "$failures"
  local warns
  warns="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8")).get("warnings") or []))' "$VERDICT_FILE")"
  metric "gateway_pipeline_warnings{project=\"$project\"}" "$warns"

  if [ -n "${CI_PIPELINE_DURATION_SECONDS:-}" ]; then
    metric "gateway_pipeline_duration_seconds{project=\"$project\"}" "$CI_PIPELINE_DURATION_SECONDS"
  else
    log_warn "skipped metric=duration_seconds reason=not_reported_by_runner"
  fi

  log INFO "audit release=$version project=$project passed=$passed warnings=$warns pipeline=${CI_PIPELINE_ID:-local} metrics=$METRICS_FILE"
  log INFO "written file=$METRICS_FILE metrics=$(metric_count)"
  push
}

cmd_deploy() {
  local env="" seconds=""
  while [ $# -gt 0 ]; do case "$1" in
    --env) env="$2"; shift 2;; --seconds) seconds="$2"; shift 2;; *) die bad_arg "arg=$1";; esac; done
  [ -n "$env" ] || die no_env "flag=--env"
  local project="${CI_PROJECT_NAME:-unknown}"
  if [ -n "$seconds" ]; then
    metric "gateway_deploy_ready_seconds{project=\"$project\",env=\"$env\"}" "$seconds"
    log INFO "audit deploy project=$project env=$env ready_seconds=$seconds"
  else
    log_warn "skipped metric=deploy_ready_seconds reason=not_measured env=$env"
  fi
  log INFO "written file=$METRICS_FILE metrics=$(metric_count)"
  push
}

selftest() {
  local fails=0
  says() { grep -q "$2" "$1" || { echo "observability selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  never_says() { if grep -q "$2" "$1"; then echo "observability selftest FAIL $3" >&2; fails=$((fails+1)); fi; return 0; }
  try() { "$@" >out.txt 2>err.txt || true; }

  tmp="$(mktemp -d)"; cd "$tmp"
  export CI_PROJECT_NAME=core-api CI_PIPELINE_ID=1421 PUSHGATEWAY_URL=

  # Without a verdict: no metrics, and the failure is named.
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says err.txt "reason=no_verdict" "a missing verdict is not reported in silence"
  eq_count() { [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ] || { echo "observability selftest FAIL $3: $(wc -l < "$1") lines, expected $2" >&2; fails=$((fails+1)); }; return 0; }
  eq_count metrics.prom 0 "the metrics file stays populated without a verdict"

  printf '%s\n' '{"passed":true,"failures":[],"warnings":["2 medium findings accepted"],"plan":[]}' > gate-verdict.json
  printf '%s\n' '{"version":"R1.4.3","status":"success"}' > build-info.json

  # Duration not sent: the metric must not appear, let alone with the value 0.
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_release_passed{project="core-api",version="R1.4.3"} 1' "passes not written correctly"
  says metrics.prom 'gateway_gate_failures{project="core-api"} 0' "the count of gate reasons not written"
  never_says metrics.prom "duration_seconds" "duration written even with no data"
  says err.txt "reason=not_reported_by_runner" "the reason for holding back not stated"
  says err.txt "skipped reason=no_pushgateway_url" "an empty pushgateway not reported"
  says err.txt 'metric name=gateway_release_passed labels=project="core-api",version="R1.4.3" value=1' "a series was written without being named"
  says err.txt 'metric name=gateway_gate_failures labels=project="core-api" value=0' "the gate reason count was not named"
  says err.txt "written file=metrics.prom metrics=3" "the file and the number of lines in it were not reported"

  # With a real duration, the number passes through unchanged.
  try env CI_PIPELINE_ID=1421 CI_PIPELINE_DURATION_SECONDS=412 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_pipeline_duration_seconds{project="core-api"} 412' "the real duration not written"

  # A refusing verdict must read as 0, not go missing.
  printf '%s\n' '{"passed":false,"failures":["vulnerabilities: 1 critical (allowed 0)"],"warnings":[],"plan":[]}' > gate-verdict.json
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_release_passed{project="core-api",version="R1.4.3"} 0' "a red verdict not written as 0"

  # Deploy without a measurement: no number, and the reason is stated.
  try env bash "$SCRIPT_DIR/observability-push.sh" deploy --env sit
  says err.txt "reason=not_measured" "a deploy with no duration leaves the reason unstated"

  # Deploy with a measurement: the series is named the moment it is written.
  try env bash "$SCRIPT_DIR/observability-push.sh" deploy --env sit --seconds 93
  says err.txt 'metric name=gateway_deploy_ready_seconds labels=project="core-api",env="sit" value=93' "a measured deploy was not named"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "observability selftest: ok" >&2; return 0; fi
  echo "observability selftest: $fails failures" >&2; return 1
}

main() {
  local cmd="${1:-}"; shift || true
  log_init "${CI_JOB_NAME:-observability}"
  case "$cmd" in
    pipeline) cmd_pipeline "$@" ;;
    deploy)   cmd_deploy "$@" ;;
    --selftest|selftest) selftest ;;
    *) printf 'usage: observability-push.sh pipeline|deploy --env N [--seconds S] | --selftest\n' >&2; exit 2 ;;
  esac
}

main "$@"
