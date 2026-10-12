#!/bin/bash
# Generates ci-library/examples/transcript.txt.
#
# The transcript is not a hand-typed example: it is the stdout+stderr of the real
# release-stamp -> gate -> ticket-sync -> observability -> deploy chain, run
# with DRY_RUN=1 and the inputs in ci-library/examples/. The /pipelines/ page in
# my portfolio uses the line shape from this transcript, so if a script
# changes its log format, the transcript and that page change with it.
#
#   bash ci-library/examples/replay.sh            # write the transcript
#   bash ci-library/examples/replay.sh --check    # verify the shape, without writing
#
# Needs: python3, groovy, and this repo. Needs no network, needs no runner.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/transcript.txt"
LINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[+-][0-9]{2}:[0-9]{2} (TRACE|DEBUG|INFO|WARN|ERROR) [a-z0-9._:-]+ .*$'

cd "$ROOT"
WORK="$(mktemp -d)"
# The files this chain produces are job artifacts, not repo content: all their
# names are in .gitignore, and they are cleaned up here so that one run does
# not leave a trace.
GEN="build-info.json gate-verdict.json gate-summary.txt image-digest.txt metrics.prom sbom.json target rendered"
cleanup() { rm -rf "$WORK"; cd "$ROOT"; for f in $GEN; do rm -rf "$f"; done; }
trap cleanup EXIT

emit() { printf '%s\n' "$*" >> "$WORK/trace"; }

make_sbom() {
  cat > sbom.json <<'JSON'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    { "type": "library", "name": "jackson-databind", "version": "2.15.0", "purl": "pkg:maven/com.fasterxml.jackson.core/jackson-databind@2.15.0" },
    { "type": "library", "name": "snakeyaml", "version": "2.0", "purl": "pkg:maven/org.yaml/snakeyaml@2.0" }
  ]
}
JSON
}

run_chain() {
  # Every command below is the same one the pipeline template runs.
  # Only DRY_RUN and the file paths differ.
  export DRY_RUN=1 \
         CI_PROJECT_NAME=core-api CI_PIPELINE_ID=1421 \
         CI_COMMIT_SHORT_SHA=a1b2c3d CI_COMMIT_REF_NAME=fix/471-timeout \
         CI_PIPELINE_URL="https://gitlab.example.internal/platform/core-api/-/pipelines/1421" \
         REGISTRY=registry.example.internal/platform

  mkdir -p target && printf 'not a real jar' > target/core-api-R0.1.0.jar

  CI_JOB_NAME=build:release-stamp python3 ci-library/tools/release_stamp.py \
    --tag-prefix R --output build-info.json --artifact target/core-api-R0.1.0.jar --audit-line \
    > "$WORK/out.txt" 2>> "$WORK/trace"

  make_sbom
  CI_JOB_NAME=scan:sbom-index python3 ci-library/tools/release_stamp.py --verify-sbom sbom.json \
    > "$WORK/out.txt" 2>> "$WORK/trace"

  for scan in trivy-report trivy-refused; do
    CI_JOB_NAME=gate:release-rules groovy -cp shared-library/src ci-library/scripts/run-gate.groovy \
      --manifest ci-library/examples/release.json \
      --scan "ci-library/examples/$scan.json" \
      --quality ci-library/examples/sonar-gate.json \
      --build build-info.json \
      > "$WORK/gate-$scan.out" 2>> "$WORK/trace" || true
    emit "# scan=$scan verdict=$(cat gate-summary.txt)"
    cp gate-verdict.json "$WORK/gate-$scan.json"
  done

  # The ticket comment for a REJECTING verdict: that is the one people most need to read.
  # Its stdout is the comment body, not a log: it goes to $WORK, so the transcript
  # stays in one line shape.
  CI_JOB_NAME=gate:ticket-sync bash ci-library/scripts/ticket-sync.sh post --issue 471 > "$WORK/ticket-note.txt" 2>> "$WORK/trace" || true
  emit "# ticket note written lines=$(wc -l < "$WORK/ticket-note.txt" | tr -d ' ')"

  cp "$WORK/gate-trivy-refused.json" gate-verdict.json
  CI_JOB_NAME=feedback:observability bash ci-library/scripts/observability-push.sh pipeline > "$WORK/out.txt" 2>> "$WORK/trace" || true

  cp "$WORK/gate-trivy-report.json" gate-verdict.json
  printf '%s\n' 'sha256:6f1a2c34d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80' > image-digest.txt
  CI_JOB_NAME=deploy:sit bash ci-library/scripts/deploy.sh apply --env sit --digest "$(cat image-digest.txt)" > "$WORK/out.txt" 2>> "$WORK/trace" || true
  CI_JOB_NAME=deploy:sit bash ci-library/scripts/deploy.sh wait --env sit --timeout 300 > "$WORK/out.txt" 2>> "$WORK/trace" || true
  CI_JOB_NAME=promote:prod bash ci-library/scripts/deploy.sh promote --from uat --to prod > "$WORK/out.txt" 2>> "$WORK/trace" || true
}

check() {
  [ -f "$OUT" ] || { echo "replay: the transcript has not been written yet" >&2; return 1; }
  local bad=0 lines=0
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    lines=$((lines+1))
    printf '%s' "$line" | grep -Eq "$LINE_RE" || { echo "replay FAIL line $lines does not match the shape: $line" >&2; bad=$((bad+1)); }
  done < "$OUT"
  grep -q 'gate failed' "$OUT" || { echo "replay FAIL: no refusing verdict in the transcript" >&2; bad=$((bad+1)); }
  grep -q 'reason=promotion_refused\|applied env=sit' "$OUT" || { echo "replay FAIL: the deploy step is missing" >&2; bad=$((bad+1)); }
  if [ "$bad" = "0" ]; then echo "replay: ok, $lines log lines of one shape"; return 0; fi
  echo "replay: $bad problems" >&2; return 1
}

case "${1:-write}" in
  --check) check ;;
  write)
    run_chain
    {
      printf '# Generated by ci-library/examples/replay.sh at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '# Input: ci-library/examples/{release.json,trivy-report.json,trivy-refused.json,sonar-gate.json}\n'
      printf '# Every command ran with DRY_RUN=1; no real system was touched.\n\n'
      cat "$WORK/trace"
    } > "$OUT"
    check
    echo "transcript: $OUT ($(( $(wc -l < "$OUT") )) lines)"
    ;;
  *) echo "usage: replay.sh [--check]" >&2; exit 2 ;;
esac
