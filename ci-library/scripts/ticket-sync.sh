#!/bin/bash
# Menempelkan verdict gate ke tiket, dari sisi pipeline.
#
# Kerjanya ada di ci-library/tools/ticket_sync.py (retry, idempotency, bentuk
# permintaan). Yang dilakukan file ini hanya memutuskan tiket mana yang dimaksud,
# karena keputusan itu datang dari tiga tempat dengan prioritas berbeda:
#
#   1. --issue / GITLAB_ISSUE       eksplisit, dari orang yang menjalankan
#   2. pesan commit                 "See #471" atau "fin-471"
#   3. release.json                 field tracker, untuk pipeline yang dipicu
#                                   webhook dari sistem tiket
#
# Kalau ketiganya kosong, file ini TIDAK menebak. Ia mencetak verdict ke stdout
# dan keluar nol: pipeline yang mengirim komentar ke tiket salah lebih merusak
# daripada pipeline yang tidak mengirim komentar.
#
# Pemakaian:
#   ticket-sync.sh post [--issue 471] [--jira FIN-471]
#   ticket-sync.sh --selftest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

DRY_RUN="${DRY_RUN:-0}"
VERDICT_FILE="${VERDICT_FILE:-gate-verdict.json}"
MANIFEST="${MANIFEST:-release.json}"
TOOLS="${SCRIPT_DIR}/../tools"

die() { log_fail "$1" "${@:2}"; exit 1; }

# Nomor tiket dari pesan commit. Dua bentuk diterima: referensi GitLab (#471)
# dan kunci tiket sistem lain (FIN-471), karena pipeline ini dipakai oleh repo
# yang trackernya bukan GitLab.
#
# Sengaja pakai grep -o, bukan sed dengan `.*` di depan: `.*` itu serakah, jadi
# "after FIN-471" pernah terbaca sebagai "IN-471" dan selftest menangkapnya.
issue_from_commit() {
  printf '%s' "$(printf '%s' "${1:-}" | grep -oE '#[0-9]{1,8}' | head -1 | tr -d '#')"
}

tracker_from_commit() {
  printf '%s' "$(printf '%s' "${1:-}" | grep -oE '[A-Z]{2,10}-[0-9]{1,6}' | head -1)"
}

tracker_from_manifest() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  python3 - "$file" <<'PY' 2>/dev/null || printf ''
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("tracker") or "")
PY
}

cmd_post() {
  local issue="${GITLAB_ISSUE:-}" jira="${JIRA_ISSUE:-}" subject=""
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issue="$2"; shift 2;; --jira) jira="$2"; shift 2;; *) die bad_arg "arg=$1";; esac; done

  subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
  [ -n "$issue" ] || issue="$(issue_from_commit "$subject")"
  [ -n "$jira" ] || jira="$(tracker_from_commit "$subject")"
  [ -n "$jira" ] || jira="$(tracker_from_manifest "$MANIFEST")"

  local source="none"
  if [ -n "${GITLAB_ISSUE:-}" ]; then source="env"; elif [ -n "$issue" ]; then source="commit"; elif [ -n "$jira" ]; then source="tracker"; fi
  log INFO "resolve gitlab_issue=${issue:-none} jira_issue=${jira:-none} source=$source"

  local args=(--verdict "$VERDICT_FILE")
  [ -n "$issue" ] && args+=(--gitlab-issue "$issue")
  [ -n "$jira" ] && args+=(--jira-issue "$jira")
  [ "$DRY_RUN" = "1" ] && args+=(--dry-run)

  python3 "$TOOLS/ticket_sync.py" "${args[@]}"
}

selftest() {
  local fails=0
  says() { grep -q "$2" "$1" || { echo "ticket-sync selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  eq()   { [ "$2" = "$3" ] || { echo "ticket-sync selftest FAIL $1: dapat '$2' mau '$3'" >&2; fails=$((fails+1)); }; return 0; }
  try()  { "$@" >out.txt 2>err.txt || true; }

  tmp="$(mktemp -d)"; cd "$tmp"
  export CI_PROJECT_NAME=core-api CI_PIPELINE_ID=1421

  eq "issue dari pesan commit" "$(issue_from_commit 'Merge branch fix/471-timeout into master #471')" "471"
  eq "tanpa referensi, kosong" "$(issue_from_commit 'just a subject')" ""
  eq "kunci tracker terbaca" "$(tracker_from_commit 'fix timeout after FIN-471 approval')" "FIN-471"
  eq "tracker dari manifest" "$(printf '%s' '{"tracker":"BOS-9"}' > release.json && tracker_from_manifest release.json)" "BOS-9"
  eq "manifest hilang bukan error" "$(tracker_from_manifest tidak-ada.json)" ""

  # Tidak ada tiket yang bisa dituju: verdict tetap tercetak, kode keluar nol.
  try env DRY_RUN=1 GITLAB_ISSUE= JIRA_ISSUE= CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/ticket-sync.sh" post
  says out.txt "pipeline" "verdict tidak tercetak saat tidak ada tiket"

  # Verdict hilang: yang terkirim adalah penolakan, bukan kelulusan.
  printf '%s\n' '{"passed":false,"summary":"gate failed: 1 critical","failures":["vulnerabilities: 1 critical (allowed 0)"],"plan":[]}' > gate-verdict.json
  try env DRY_RUN=1 GITLAB_ISSUE=471 JIRA_ISSUE= CI_PIPELINE_URL=https://gitlab.example.internal/x/-/pipelines/1421 \
    bash "$SCRIPT_DIR/ticket-sync.sh" post
  says err.txt "gitlab_issue=471" "tiket dari argumen tidak dipakai"
  says out.txt "BLOCKED" "verdict merah tidak tertulis sebagai kelulusan"
  says out.txt "idempotency: gate-" "kunci idempotency hilang"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "ticket-sync selftest: ok" >&2; return 0; fi
  echo "ticket-sync selftest: $fails kegagalan" >&2; return 1
}

main() {
  local cmd="${1:-}"; shift || true
  log_init "${CI_JOB_NAME:-ticket-sync}"
  case "$cmd" in
    post) cmd_post "$@" ;;
    --selftest|selftest) selftest ;;
    *) printf 'usage: ticket-sync.sh post [--issue N] [--jira KEY-N] | --selftest\n' >&2; exit 2 ;;
  esac
}

main "$@"
