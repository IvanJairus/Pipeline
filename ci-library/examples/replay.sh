#!/bin/bash
# Menghasilkan ci-library/examples/transcript.txt.
#
# Transkrip itu bukan contoh yang diketik tangan: ia stdout+stderr dari rantai
# nyata release-stamp -> gate -> ticket-sync -> observability -> deploy, dijalankan
# dengan DRY_RUN=1 dan input di ci-library/examples/. Halaman /pipelines/ di
# portofolio saya memakai bentuk baris dari transkrip ini, jadi kalau sebuah
# script mengubah format lognya, transkrip dan halaman itu ikut berubah.
#
#   bash ci-library/examples/replay.sh            # tulis transkrip
#   bash ci-library/examples/replay.sh --check    # verifikasi bentuknya, tanpa menulis
#
# Butuh: python3, groovy, dan repo ini. Tidak butuh jaringan, tidak butuh runner.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/transcript.txt"
LINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[+-][0-9]{2}:[0-9]{2} (TRACE|DEBUG|INFO|WARN|ERROR) [a-z0-9._:-]+ .*$'

cd "$ROOT"
WORK="$(mktemp -d)"
# Berkas yang dihasilkan rantai ini adalah artefak job, bukan isi repo: semua
# namanya ada di .gitignore, dan dibersihkan di sini supaya sekali jalan tidak
# meninggalkan jejak.
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
  # Semua perintah di bawah adalah perintah yang sama dengan yang ada di
  # template pipeline; yang berbeda hanya DRY_RUN dan jalur berkasnya.
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

  # Komentar tiket untuk verdict yang MENOLAK - itu yang paling perlu dibaca orang.
  # stdout-nya adalah isi komentar, bukan log: ia ke $WORK, supaya transkrip tetap
  # satu bentuk baris.
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
  [ -f "$OUT" ] || { echo "replay: transkrip belum dibuat" >&2; return 1; }
  local bad=0 lines=0
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    lines=$((lines+1))
    printf '%s' "$line" | grep -Eq "$LINE_RE" || { echo "replay FAIL baris $lines tidak seformat: $line" >&2; bad=$((bad+1)); }
  done < "$OUT"
  grep -q 'gate failed' "$OUT" || { echo "replay FAIL: tidak ada verdict menolak di transkrip" >&2; bad=$((bad+1)); }
  grep -q 'reason=promotion_refused\|applied env=sit' "$OUT" || { echo "replay FAIL: langkah deploy hilang" >&2; bad=$((bad+1)); }
  if [ "$bad" = "0" ]; then echo "replay: ok, $lines baris log seragam"; return 0; fi
  echo "replay: $bad masalah" >&2; return 1
}

case "${1:-write}" in
  --check) check ;;
  write)
    run_chain
    {
      printf '# Dihasilkan oleh ci-library/examples/replay.sh pada %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '# Input: ci-library/examples/{release.json,trivy-report.json,trivy-refused.json,sonar-gate.json}\n'
      printf '# Semua perintah dijalankan dengan DRY_RUN=1; tidak ada sistem nyata yang disentuh.\n\n'
      cat "$WORK/trace"
    } > "$OUT"
    check
    echo "transkrip: $OUT ($(( $(wc -l < "$OUT") )) baris)"
    ;;
  *) echo "usage: replay.sh [--check]" >&2; exit 2 ;;
esac
