#!/bin/bash
# Push the build artifact to the place it will be pulled from at deploy time.
#
# Used by the build:docker-image (kaniko), publish:maven (library), sign:apk
# and distribute:internal-track (mobile) jobs. One file, four artifact shapes,
# one way to answer the same question: "which version just went up, and from
# which commit?"
#
# Usage:
#   publish-artifact.sh push          # image, write image-digest.txt
#   publish-artifact.sh maven         # jar to the maven registry
#   publish-artifact.sh sign          # apk signature
#   publish-artifact.sh distribute --track internal
#   publish-artifact.sh --selftest
#
# Environment:
#   DRY_RUN=1        print the command, do not run it (used by selftest and locally)
#   REGISTRY         image destination, required
#   LOG_LEVEL        TRACE|DEBUG|INFO|WARN|ERROR (default INFO)
#
# What this file does not do: it never writes a `latest` tag. An image with no
# digest cannot be pointed back to by an incident six months later, and
# `latest` is the politest way to make a deploy unrepeatable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

BUILD_INFO="${BUILD_INFO:-build-info.json}"
DIGEST_FILE="${DIGEST_FILE:-image-digest.txt}"
DRY_RUN="${DRY_RUN:-0}"

die() { log_fail "$1" "${@:2}"; exit 1; }

# The size of a file, or "absent" when the file is not there. A missing file
# printed as 0 would read as "an empty artifact", which is a different fact and
# the wrong one.
file_bytes() {
  local f="$1"
  if [ -f "$f" ]; then printf '%s' "$(( $(wc -c < "$f") ))"; else printf 'absent'; fi
}

# Non-empty lines in a captured command output: what a tool actually answered.
line_count() { printf '%s' "$1" | grep -c . || true; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    log INFO "would run $*"
    return 0
  fi
  log DEBUG "exec $*"
  "$@"
}

# Read one key from build-info.json without calling jq: runner images do not
# always ship jq, and a job that fails over a missing helper tool is not the
# failure anyone wants to explain at two in the morning.
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
  # Named once, then used by both the log line and the command, so the two
  # cannot drift apart and print a context the build never used.
  local context dockerfile
  context="dir://$(pwd)"
  dockerfile="Dockerfile"
  local ref="$REGISTRY/$CI_PROJECT_NAME:$VERSION"
  log INFO "preflight context=$context dockerfile=$dockerfile registry=$REGISTRY project=${CI_PROJECT_NAME:-none}"
  log INFO "push ref=$ref kaniko=true"
  run /kaniko/executor \
    --context "$context" \
    --dockerfile "$dockerfile" \
    --destination "$ref" \
    --digest-file "$DIGEST_FILE" \
    --snapshot-mode=redo
  local digest algo hex
  digest="$(cat "$DIGEST_FILE" 2>/dev/null || true)"
  [ -n "${digest:-}" ] || die no_digest "file=$DIGEST_FILE the push produced nothing to point at"
  case "$digest" in
    sha256:*) log INFO "digest written file=$DIGEST_FILE algorithm=sha256" ;;
    *) die bad_digest "value=$digest expected=sha256:<hex>" ;;
  esac
  # Read back from the file rather than echoed from the argument: the value
  # printed here is the value the next job will find on disk.
  algo="${digest%%:*}"
  hex="$(printf '%s' "${digest#*:}" | tr -d '[:space:]')"
  log INFO "digest read file=$DIGEST_FILE value=${algo}:${hex} algorithm=$algo hexLength=${#hex}"
  log INFO "artifact written=$DIGEST_FILE bytes=$(file_bytes "$DIGEST_FILE") destination=$ref"
}

cmd_maven() {
  require_version
  : "${MAVEN_GROUP:?MAVEN_GROUP required to publish a library}"
  : "${MAVEN_REPO:?MAVEN_REPO required to publish a library}"
  # The coordinates as they are put on the wire: `version` is the release stamp,
  # `revision` is the value maven is handed, and the two are not the same string.
  log INFO "publish groupId=$MAVEN_GROUP artifactId=$CI_PROJECT_NAME version=$VERSION revision=${VERSION#*.} repository=$MAVEN_REPO"
  log DEBUG "mvn flags=batch,quiet goals=deploy revision=${VERSION#*.} altDeploymentRepository=internal::$MAVEN_REPO"
  run mvn -B -q deploy \
    -Drevision="${VERSION#*.}" \
    -DaltDeploymentRepository="internal::$MAVEN_REPO"
}

cmd_sign() {
  require_version
  local apk="" f candidates=0 skippedSigned=0 out
  for f in app/build/outputs/apk/release/*.apk; do
    [ -e "$f" ] || continue
    candidates=$((candidates+1))
    case "$f" in *signed*) skippedSigned=$((skippedSigned+1)); continue ;; esac
    apk="$f"; break
  done
  [ -n "$apk" ] || die no_apk "pattern=app/build/outputs/apk/release/*.apk"
  log INFO "select pattern=app/build/outputs/apk/release/*.apk candidates=$candidates skippedSigned=$skippedSigned chosen=$(basename "$apk")"
  keystore="${KEYSTORE_PATH:?KEYSTORE_PATH issued by setup-vault-jwt.sh}"
  : "${KEYSTORE_ALIAS:?KEYSTORE_ALIAS required to sign}"
  # The name and the size of the lease, never its contents: a lease is readable
  # for exactly one job, so whether the file is still on disk is itself a fact.
  log INFO "sign apk=$(basename "$apk") keystore=lease-id-$(basename "$keystore")"
  log INFO "lease var=KEYSTORE_PATH file=$(basename "$keystore") bytes=$(file_bytes "$keystore") alias=$KEYSTORE_ALIAS"
  out="${apk%.apk}-signed.apk"
  log DEBUG "apksigner flags=keyStore,ksKeyAlias,out in=$(basename "$apk") out=$(basename "$out")"
  run apksigner sign --ks "$keystore" --ks-key-alias "$KEYSTORE_ALIAS" --out "$out"
  if [ "$DRY_RUN" = "1" ]; then
    log INFO "skipped reason=dry_run verify=not_attempted out=$(basename "$out")"
    return 0
  fi
  local certs status=0 signers
  certs="$(apksigner verify --print-certs "$out" 2>&1)" || status=$?
  if [ "$status" != "0" ]; then
    die verify_failed "apk=$(basename "$out") exit=$status lease=$(basename "$keystore")"
  fi
  signers="$(printf '%s\n' "$certs" | grep -c '^Signer #' || true)"
  log INFO "verified apk=$(basename "$out") signers=$signers bytes=$(file_bytes "$out")"
}

cmd_distribute() {
  # mobile.yml calls this as `distribute --track internal`; a bare
  # `distribute internal` is accepted too. Reading $1 as the value, which the
  # first version did, turned the flag itself into a track name and died.
  local track="internal"
  while [ $# -gt 0 ]; do
    case "$1" in
      --track) track="${2:-}"; shift 2 ;;
      *) track="$1"; shift ;;
    esac
  done
  case "$track" in
    internal|alpha|beta) ;;
    *) die bad_track "value=$track allowed=internal|alpha|beta production goes through promote:prod, not through here" ;;
  esac
  local apk upload
  apk="$(ls app/build/outputs/apk/release/*-signed.apk 2>/dev/null | head -1 || true)"
  [ -n "$apk" ] || die unsigned "reason=no_signed_apk a bundle reaches a track only after sign:apk"
  require_version
  log INFO "distribute track=$track file=$(basename "$apk") version=$VERSION"
  log INFO "artifact path=$(basename "$apk") bytes=$(file_bytes "$apk") track=$track"
  # Built once so that the line written to the log and the line that runs are the
  # same line.
  upload=(bundletool upload --track "$track" --artifact "$apk")
  if [ "$DRY_RUN" != "1" ]; then
    local response status=0
    log DEBUG "exec ${upload[*]}"
    response="$("${upload[@]}" 2>&1)" || status=$?
    if [ "$status" != "0" ]; then
      die upload_failed "track=$track artifact=$(basename "$apk") exit=$status"
    fi
    log INFO "uploaded track=$track artifact=$(basename "$apk") responseLines=$(line_count "$response")"
    return 0
  fi
  run "${upload[@]}"
  log INFO "skipped reason=dry_run upload=not_attempted track=$track artifact=$(basename "$apk")"
}

selftest() {
  local fails=0 tmp
  says()      { grep -q "$2" "$1" || { echo "publish-artifact selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  never_says(){ if grep -q "$2" "$1"; then echo "publish-artifact selftest FAIL $3" >&2; fails=$((fails+1)); fi; return 0; }

  tmp="$(mktemp -d)"
  cd "$tmp"

  # Without build-info.json: it must stop, not guess a version.
  DRY_RUN=1 REGISTRY=registry.example.internal/platform CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "reason=no_version" "a missing version must stop the push"

  printf '%s\n' '{"version":"R1.4.3","commit":"a1b2c3d","status":"success"}' > build-info.json

  # Push in dry-run: the ref uses the version, never latest.
  DRY_RUN=1 REGISTRY=registry.example.internal/platform CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "ref=registry.example.internal/platform/core-api:R1.4.3" "the ref does not use the version"
  never_says err.txt ":latest" "latest must never appear"

  # A malformed digest must be caught here, not stored and then detonating at deploy.
  printf '%s\n' 'notadigest' > image-digest.txt
  DRY_RUN=1 REGISTRY=r CI_PROJECT_NAME=core-api bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "reason=bad_digest" "a malformed digest went unnoticed"
  printf '%s\n' 'sha256:6f1a2c34d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80' > image-digest.txt
  DRY_RUN=1 REGISTRY=r CI_PROJECT_NAME=core-api bash "$SCRIPT_DIR/publish-artifact.sh" push >out.txt 2>err.txt || true
  says err.txt "digest written" "a valid digest went unrecorded"
  says err.txt "preflight context=dir://" "the build context was never written down"
  says err.txt "dockerfile=Dockerfile" "the Dockerfile used was never written down"
  says err.txt "digest read file=image-digest.txt value=sha256:6f1a" "the digest was not read back from the file"
  says err.txt "algorithm=sha256 hexLength=64" "the digest algorithm was not named with the value"
  says err.txt "artifact written=image-digest.txt bytes=72" "the artifact file left on disk was not sized"

  # The library coordinates, as they go on the wire.
  DRY_RUN=1 CI_PROJECT_NAME=ledger-client MAVEN_GROUP=com.example.ledger MAVEN_REPO=https://nexus.example.internal/repository/maven-releases/ \
    bash "$SCRIPT_DIR/publish-artifact.sh" maven >out.txt 2>err.txt || true
  says err.txt "groupId=com.example.ledger artifactId=ledger-client version=R1.4.3" "the coordinates were not written down"
  says err.txt "repository=https://nexus.example.internal/repository/maven-releases/" "the target repository was not named"

  # Production tracks do not go through this path.
  DRY_RUN=1 bash "$SCRIPT_DIR/publish-artifact.sh" distribute production >out.txt 2>err.txt || true
  says err.txt "reason=bad_track" "production track refused"

  # An unsigned bundle must not reach any track.
  mkdir -p app/build/outputs/apk/release
  printf 'x' > app/build/outputs/apk/release/app-release.apk
  DRY_RUN=1 bash "$SCRIPT_DIR/publish-artifact.sh" distribute internal >out.txt 2>err.txt || true
  says err.txt "reason=unsigned" "unsigned bundle refused"

  # mobile.yml passes the track as a flag. Reading $1 as the value made the flag
  # itself the track name, so both spellings have to be accepted. Run in its own
  # directory: the signing case below counts the bundles it finds in the cwd.
  mkdir -p track/app/build/outputs/apk/release
  printf 'x' > track/app/build/outputs/apk/release/app-release-signed.apk
  printf '%s\n' '{"version":"R1.4.3","commit":"a1b2c3d","status":"success"}' > track/build-info.json
  ( cd track && DRY_RUN=1 bash "$SCRIPT_DIR/publish-artifact.sh" distribute --track internal ) >out.txt 2>err.txt || true
  never_says err.txt "reason=bad_track" "the --track spelling was refused"
  says err.txt "distribute track=internal" "the --track spelling was not read"

  # Signing: the lease is named by its file name and its size, never by what is
  # inside it, and a dry run says plainly that nothing was verified.
  printf '0123456789' > lease-1421.keystore
  DRY_RUN=1 CI_PROJECT_NAME=mobile-app KEYSTORE_PATH="$tmp/lease-1421.keystore" KEYSTORE_ALIAS=release \
    bash "$SCRIPT_DIR/publish-artifact.sh" sign >out.txt 2>err.txt || true
  says err.txt "chosen=app-release.apk" "the apk that was picked is not named"
  says err.txt "candidates=1 skippedSigned=0" "the selection did not count what it looked at"
  says err.txt "lease var=KEYSTORE_PATH file=lease-1421.keystore bytes=10" "the lease file is not named"
  never_says err.txt "0123456789" "the keystore bytes were written into the log"
  says err.txt "skipped reason=dry_run verify=not_attempted" "a dry-run sign claimed a verification"

  # A signed bundle on a track: the artifact and its size are read from disk.
  printf '0123456789012345' > app/build/outputs/apk/release/app-release-signed.apk
  DRY_RUN=1 CI_PROJECT_NAME=mobile-app bash "$SCRIPT_DIR/publish-artifact.sh" distribute internal >out.txt 2>err.txt || true
  says err.txt "distribute track=internal file=app-release-signed.apk version=R1.4.3" "the track or the artifact not named"
  says err.txt "artifact path=app-release-signed.apk bytes=16 track=internal" "the upload artifact was not sized"
  says err.txt "skipped reason=dry_run upload=not_attempted track=internal" "a dry-run upload claimed a result"

  # The log line shape every other script uses.
  ( source "$SCRIPT_DIR/lib/log.sh"; log_selftest ) || { echo "publish-artifact selftest FAIL log.sh" >&2; fails=$((fails+1)); }

  cd /
  rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "publish-artifact selftest: ok" >&2; return 0; fi
  echo "publish-artifact selftest: $fails failures" >&2; return 1
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
