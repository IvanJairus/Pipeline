#!/bin/bash
# Mendorong hasil satu pipeline ke agregator metrik, dan menulis satu baris audit.
#
# Dipanggil oleh job feedback:observability (when: always) dan oleh after_script
# deploy di template platform.
#
# Pemakaian:
#   observability-push.sh pipeline
#   observability-push.sh deploy --env sit --seconds 93
#   observability-push.sh --selftest
#
# Environment:
#   PUSHGATEWAY_URL   tujuan POST; kosong berarti hanya menulis berkas
#   METRICS_FILE      default metrics.prom
#   DRY_RUN=1         jangan kirim, cukup cetak
#
# Dua aturan yang menahan file ini supaya datanya masih bisa dipercaya:
#
#   1. Tidak ada angka yang dikarang. Durasi hanya ditulis kalau GitLab memang
#      mengirimkannya (CI_PIPELINE_DURATION_SECONDS). Kalau tidak ada, metriknya
#      tidak ada - bukan 0, karena 0 berarti "seketika" dan itu dibaca sebagai
#      kabar baik oleh siapa pun yang punya dashboard.
#   2. Verdict yang hilang bukan kelulusan. release_passed hanya ditulis kalau
#      gate-verdict.json benar-benar ada; kalau tidak, tidak ada angka sama sekali.

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

metric() { printf '%s %s\n' "$1" "$2" >> "$METRICS_FILE"; }

push() {
  if [ -z "$PUSHGATEWAY_URL" ]; then
    log_warn "skipped reason=no_pushgateway_url file=$METRICS_FILE metrics=$(( $(wc -l < "$METRICS_FILE") ))"
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
    # Sengaja tidak menulis release_passed=0: itu akan terlihat seperti "gate
    # menolak", padahal yang terjadi adalah tidak ada keputusan untuk dibaca.
    log_error "failed reason=no_verdict file=$VERDICT_FILE metrics_written=0"
    die no_verdict "file=$VERDICT_FILE nothing can be reported about a decision that was never made"
  fi
  passed="$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1],encoding="utf-8")).get("passed") else 0)' "$VERDICT_FILE")"

  metric "gateway_release_passed{project=\"$project\",version=\"$version\"}" "$passed"
  # Yang dihitung di sini adalah jumlah alasan, bukan jumlah temuan: temuan
  # mentah sudah ada di artefak scan, dan menyalinnya ke metrik hanya memberi
  # dua angka yang bisa berbeda.
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
  push
}

selftest() {
  local fails=0
  says() { grep -q "$2" "$1" || { echo "observability selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  never_says() { if grep -q "$2" "$1"; then echo "observability selftest FAIL $3" >&2; fails=$((fails+1)); fi; return 0; }
  try() { "$@" >out.txt 2>err.txt || true; }

  tmp="$(mktemp -d)"; cd "$tmp"
  export CI_PROJECT_NAME=core-api CI_PIPELINE_ID=1421 PUSHGATEWAY_URL=

  # Tanpa verdict: tidak ada metrik, dan kegagalannya bernama.
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says err.txt "reason=no_verdict" "verdict hilang tidak dilaporkan diam-diam"
  eq_count() { [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ] || { echo "observability selftest FAIL $3: $(wc -l < "$1") baris, mau $2" >&2; fails=$((fails+1)); }; return 0; }
  eq_count metrics.prom 0 "berkas metrik tetap berisi tanpa verdict"

  printf '%s\n' '{"passed":true,"failures":[],"warnings":["2 medium findings accepted"],"plan":[]}' > gate-verdict.json
  printf '%s\n' '{"version":"R1.4.3","status":"success"}' > build-info.json

  # Durasi tidak dikirim: metriknya tidak boleh muncul, apalagi bernilai 0.
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_release_passed{project="core-api",version="R1.4.3"} 1' "passes tidak tertulis benar"
  says metrics.prom 'gateway_gate_failures{project="core-api"} 0' "jumlah alasan gate tidak tertulis"
  never_says metrics.prom "duration_seconds" "durasi tanpa data tetap ditulis"
  says err.txt "reason=not_reported_by_runner" "alasan penundaan tidak disebut"
  says err.txt "skipped reason=no_pushgateway_url" "pushgateway kosong tidak dilaporkan"

  # Dengan durasi nyata, angkanya lewat apa adanya.
  try env CI_PIPELINE_ID=1421 CI_PIPELINE_DURATION_SECONDS=412 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_pipeline_duration_seconds{project="core-api"} 412' "durasi nyata tidak tertulis"

  # Verdict menolak harus terbaca sebagai 0, bukan hilang.
  printf '%s\n' '{"passed":false,"failures":["vulnerabilities: 1 critical (allowed 0)"],"warnings":[],"plan":[]}' > gate-verdict.json
  try env CI_PIPELINE_ID=1421 bash "$SCRIPT_DIR/observability-push.sh" pipeline
  says metrics.prom 'gateway_release_passed{project="core-api",version="R1.4.3"} 0' "verdict merah tidak tertulis 0"

  # Deploy tanpa pengukuran: tidak ada angka, ada alasannya.
  try env bash "$SCRIPT_DIR/observability-push.sh" deploy --env sit
  says err.txt "reason=not_measured" "deploy tanpa durasi tidak menjelaskan alasan"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "observability selftest: ok" >&2; return 0; fi
  echo "observability selftest: $fails kegagalan" >&2; return 1
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
