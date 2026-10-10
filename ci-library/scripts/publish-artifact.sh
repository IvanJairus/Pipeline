#!/bin/bash
# Menaikkan artefak hasil build ke tempat ia akan diambil saat deploy.
#
# Dipakai oleh job build:docker-image (kaniko), publish:maven (library),
# sign:apk dan distribute:internal-track (mobile). Satu file, empat bentuk
# artefak, satu cara menjawab pertanyaan yang sama: "versi apa yang baru saja
# naik, dan dari commit mana?"
#
# Pemakaian:
#   publish-artifact.sh push          # image, tulis image-digest.txt
#   publish-artifact.sh maven         # jar ke registry maven
#   publish-artifact.sh sign          # tanda tangan apk
#   publish-artifact.sh distribute --track internal
#   publish-artifact.sh --selftest
#
# Environment:
#   DRY_RUN=1        cetak perintah, jangan jalankan (dipakai selftest dan lokal)
#   REGISTRY         tujuan image, wajib ada
#   LOG_LEVEL        TRACE|DEBUG|INFO|WARN|ERROR (default INFO)
#
# Yang tidak dilakukan file ini: tidak pernah menulis tag `latest`. Sebuah image
# tanpa digest tidak bisa dirujuk kembali oleh insiden enam bulan lalu, dan
# `latest` adalah cara paling sopan untuk membuat deploy yang tidak bisa diulang.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

BUILD_INFO="${BUILD_INFO:-build-info.json}"
DIGEST_FILE="${DIGEST_FILE:-image-digest.txt}"
DRY_RUN="${DRY_RUN:-0}"

die() { log_fail "$1" "${@:2}"; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    log INFO "would run $*"
    return 0
  fi
  log DEBUG "exec $*"
  "$@"
}

# Baca satu kunci dari build-info.json tanpa memanggil jq: image runner tidak
# selalu punya jq, dan sebuah job yang gagal karena alat bantu bukan kegagalan
# yang ingin dijelaskan orang jam dua pagi.
info_get() {
  local key="$1"
  [ -f "$BUILD_INFO" ] || { log_warn "read ${BUILD_INFO} missing treated=absent"; return 1; }
  python3 - "$BUILD_INFO" "$key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
value = doc.get(sys.argv[2])
if value is None:
    sys.exit(3)
print(value)
PY
}

require_version() {
  VERSION="$(info_get version 2>/dev/null || true)"
  [ -n "${VERSION:-}" ] || die no_version "file=$BUILD_INFO a build cannot be published without a version"
  log INFO "resolved version=$VERSION commit=$(info_get commit 2>/dev/null || echo none)"
}

cmd_push() {
  : "${REGISTRY:?REGISTRY required to push an image}"
  require_version
  local ref="$REGISTRY/$CI_PROJECT_NAME:$VERSION"
  log INFO "push ref=$ref kaniko=true"
  run /kaniko/executor \
    --context "dir://$(pwd)" \
    --dockerfile "Dockerfile" \
    --destination "$ref" \
    --digest-file "$DIGEST_FILE" \
    --snapshot-mode=redo
  local digest
  digest="$(cat "$DIGEST_FILE" 2>/dev/null || true)"
  [ -n "${digest:-}" ] || die no_digest "file=$DIGEST_FILE the push produced nothing to point at"
  case "$digest" in
    sha256:*) log INFO "digest written file=$DIGEST_FILE algorithm=sha256" ;;
    *) die bad_digest "value=$digest expected=sha256:<hex>" ;;
  esac
}

cmd_maven() {
  require_version
  log INFO "publish groupId=$MAVEN_GROUP artifactId=$CI_PROJECT_NAME version=${VERSION#*.} repository=$MAVEN_REPO"
  run mvn -B -q deploy \
    -Drevision="${VERSION#*.}" \
    -DaltDeploymentRepository="internal::$MAVEN_REPO"
}

cmd_sign() {
  require_version
  local apk="" f
  for f in app/build/outputs/apk/release/*.apk; do
    [ -e "$f" ] || continue
    case "$f" in *signed*) continue ;; esac
    apk="$f"; break
  done
  [ -n "$apk" ] || die no_apk "pattern=app/build/outputs/apk/release/*.apk"
  keystore="${KEYSTORE_PATH:?KEYSTORE_PATH issued by setup-vault-jwt.sh}"
  log INFO "sign apk=$(basename "$apk") keystore=lease-id-$(basename "$keystore")"
  run apksigner sign --ks "$keystore" --ks-key-alias "$KEYSTORE_ALIAS" --out "${apk%.apk}-signed.apk"
  run apksigner verify --print-certs "${apk%.apk}-signed.apk"
}

cmd_distribute() {
  local track="${1:-internal}"
  case "$track" in
    internal|alpha|beta) ;;
    *) die bad_track "value=$track allowed=internal|alpha|beta production goes through promote:prod, not through here" ;;
  esac
  local apk
  apk="$(ls app/build/outputs/apk/release/*-signed.apk 2>/dev/null | head -1 || true)"
  [ -n "$apk" ] || die unsigned "reason=no_signed_apk a bundle reaches a track only after sign:apk"
  require_version
  log INFO "distribute track=$track file=$(basename "$apk") version=$VERSION"
  run bundletool upload --track "$track" --artifact "$apk"
}

selftest() {
  local fails=0 tmp
  says()      { grep -q "$2" "$1" || { echo "publish-artifact selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  never_says(){ if grep -q "$2" "$1"; then echo "publish-artifact selftest FAIL $3" >&2; fails=$((fails+1)); fi; return 0; }

  tmp="$(mktemp -d)"
  cd "$tmp"

  # Tanpa build-info.json: harus berhenti, bukan menebak versi.
  DRY_RUN=1 REGISTRY=registry.example.internal/platform CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "reason=no_version" "versi hilang harus menghentikan push"

  printf '%s\n' '{"version":"R1.4.3","commit":"a1b2c3d","status":"success"}' > build-info.json

  # Push dalam dry-run: ref memakai versi, tidak pernah memakai latest.
  DRY_RUN=1 REGISTRY=registry.example.internal/platform CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "ref=registry.example.internal/platform/core-api:R1.4.3" "ref tidak memakai versi"
  never_says err.txt ":latest" "latest tidak boleh muncul"

  # Digest yang salah bentuk harus tertangkap, bukan tersimpan lalu meledak di deploy.
  printf '%s\n' 'notadigest' > image-digest.txt
  DRY_RUN=1 REGISTRY=r CI_PROJECT_NAME=core-api bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "reason=bad_digest" "digest rusak tidak tertangkap"
  printf '%s\n' 'sha256:6f1a2c34d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80' > image-digest.txt
  DRY_RUN=1 REGISTRY=r CI_PROJECT_NAME=core-api bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "digest written" "digest sah tidak dicatat"

  # Track produksi tidak lewat jalur ini.
  DRY_RUN=1 bash "$SCRIPT_DIR/publish-artifact.sh" distribute production >out.txt 2>err.txt || true
  says err.txt "reason=bad_track" "track produksi tertolak"

  # Bundle yang belum ditandatangani tidak boleh naik ke track mana pun.
  mkdir -p app/build/outputs/apk/release
  printf 'x' > app/build/outputs/apk/release/app-release.apk
  DRY_RUN=1 bash "$SCRIPT_DIR/publish-artifact.sh" distribute internal >out.txt 2>err.txt || true
  says err.txt "reason=unsigned" "bundle tanpa tanda tangan tertolak"

  # Bentuk baris log yang dipakai semua script lain.
  ( source "$SCRIPT_DIR/lib/log.sh"; log_selftest ) || { echo "publish-artifact selftest FAIL log.sh" >&2; fails=$((fails+1)); }

  cd /
  rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "publish-artifact selftest: ok" >&2; return 0; fi
  echo "publish-artifact selftest: $fails kegagalan" >&2; return 1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    push)        log_init "${CI_JOB_NAME:-publish-artifact}"; cmd_push "$@" ;;
    maven)       log_init "${CI_JOB_NAME:-publish-artifact}"; cmd_maven "$@" ;;
    sign)        log_init "${CI_JOB_NAME:-publish-artifact}"; cmd_sign "$@" ;;
    distribute)  log_init "${CI_JOB_NAME:-publish-artifact}"; cmd_distribute "$@" ;;
    --selftest|selftest) selftest ;;
    *) cat >&2 <<'USAGE'
usage: publish-artifact.sh push|maven|sign|distribute [internal] | --selftest
USAGE
      exit 2 ;;
  esac
}

main "$@"
