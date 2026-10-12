#!/bin/bash
# Attach the gate verdict to the ticket, from the pipeline side.
#
# The work lives in ci-library/tools/ticket_sync.py (retry, idempotency, request
# shape). All this file decides is which ticket is meant, because that decision
# comes from three places with different precedence:
#
#   1. --issue / GITLAB_ISSUE       explicit, from the person running the job
#   2. commit message               "See #471" or "fin-471"
#   3. release.json                 tracker field, for pipelines triggered
#                                   by a webhook from the ticketing system
#
# If all three are empty, this file does NOT guess. It prints the verdict to
# stdout and exits zero: a pipeline that posts a comment on the wrong ticket
# does more damage than a pipeline that posts no comment.
#
# Usage:
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

# A value with spaces in it stays one value: the pairs are backslash escaped, the
# same way the other scripts write them, so one line still reads as one record.
kv() { printf '%s' "${1// /\\ }"; }

file_bytes() {
  local f="$1"
  if [ -f "$f" ]; then printf '%s' "$(( $(wc -c < "$f") ))"; else printf 'absent'; fi
}

# Ticket number from the commit message. Two forms are accepted: a GitLab
# reference (#471) and a ticket key from another system (FIN-471), because this
# pipeline is used by repos whose tracker is not GitLab.
#
# Deliberately grep -o rather than sed with `.*` in front: that `.*` is greedy,
# so "after FIN-471" was once read as "IN-471", and the selftest caught it.
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
  local issue_source="none" jira_source="none"
  [ -n "$issue" ] && issue_source="env"
  [ -n "$jira" ] && jira_source="env"
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issue="$2"; issue_source="flag"; shift 2;;
    --jira) jira="$2"; jira_source="flag"; shift 2;;
    *) die bad_arg "arg=$1";; esac; done

  subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
  # The subject is written out because it is what the next two lines were read
  # from: when the ticket id looks wrong, this is the line that explains it.
  log INFO "commit subject=$(kv "${subject:-none}") length=${#subject}"

  if [ "$issue_source" = "none" ]; then
    issue="$(issue_from_commit "$subject")"
    [ -n "$issue" ] && issue_source="commit"
  fi
  if [ "$jira_source" = "none" ]; then
    jira="$(tracker_from_commit "$subject")"
    [ -n "$jira" ] && jira_source="commit"
    if [ -z "$jira" ]; then
      jira="$(tracker_from_manifest "$MANIFEST")"
      [ -n "$jira" ] && jira_source="manifest"
    fi
  fi

  local source="none"
  if [ -n "${GITLAB_ISSUE:-}" ]; then source="env"; elif [ -n "$issue" ]; then source="commit"; elif [ -n "$jira" ]; then source="tracker"; fi
  log INFO "resolve gitlab_issue=${issue:-none} jira_issue=${jira:-none} source=$source"
  # Which of the three places each id came from, named on its own: the aggregate
  # line above can only tell one story, and a comment on the wrong ticket is
  # usually the two ids arriving from two different places.
  log INFO "provenance gitlab=${issue:-none}/${issue_source} jira=${jira:-none}/${jira_source} manifest=$MANIFEST manifestBytes=$(file_bytes "$MANIFEST")"

  local args=(--verdict "$VERDICT_FILE")
  [ -n "$issue" ] && args+=(--gitlab-issue "$issue")
  [ -n "$jira" ] && args+=(--jira-issue "$jira")
  [ "$DRY_RUN" = "1" ] && args+=(--dry-run)

  # What is about to be forwarded, stated before it is forwarded.
  log INFO "forward file=$VERDICT_FILE bytes=$(file_bytes "$VERDICT_FILE") exists=$([ -f "$VERDICT_FILE" ] && echo true || echo false)"
  log DEBUG "invoke script=ticket_sync.py flags=${#args[@]} dryRun=$DRY_RUN"

  python3 "$TOOLS/ticket_sync.py" "${args[@]}"
}

selftest() {
  local fails=0
  says() { grep -q "$2" "$1" || { echo "ticket-sync selftest FAIL $3" >&2; fails=$((fails+1)); }; return 0; }
  eq()   { [ "$2" = "$3" ] || { echo "ticket-sync selftest FAIL $1: got '$2' expected '$3'" >&2; fails=$((fails+1)); }; return 0; }
  try()  { "$@" >out.txt 2>err.txt || true; }

  tmp="$(mktemp -d)"; cd "$tmp"
  export CI_PROJECT_NAME=core-api CI_PIPELINE_ID=1421

  eq "issue from the commit message" "$(issue_from_commit 'Merge branch fix/471-timeout into master #471')" "471"
  eq "no reference, empty" "$(issue_from_commit 'just a subject')" ""
  eq "tracker key read" "$(tracker_from_commit 'fix timeout after FIN-471 approval')" "FIN-471"
  eq "tracker from the manifest" "$(printf '%s' '{"tracker":"BOS-9"}' > release.json && tracker_from_manifest release.json)" "BOS-9"
  eq "missing manifest is not an error" "$(tracker_from_manifest no-such-file.json)" ""

  # No ticket to address: the verdict is still printed, and the exit code is zero.
  try env DRY_RUN=1 GITLAB_ISSUE= JIRA_ISSUE= CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/ticket-sync.sh" post
  says out.txt "pipeline" "the verdict is not printed when no ticket exists"

  # Missing verdict: what gets sent is a refusal, not a pass.
  printf '%s\n' '{"passed":false,"summary":"gate failed: 1 critical","failures":["vulnerabilities: 1 critical (allowed 0)"],"plan":[]}' > gate-verdict.json
  try env DRY_RUN=1 GITLAB_ISSUE=471 JIRA_ISSUE= CI_PIPELINE_URL=https://gitlab.example.internal/x/-/pipelines/1421 \
    bash "$SCRIPT_DIR/ticket-sync.sh" post
  says err.txt "gitlab_issue=471" "the ticket from the argument was not used"
  says out.txt "BLOCKED" "a red verdict written as a pass"
  says out.txt "idempotency: gate-" "idempotency key missing"
  says err.txt "commit subject=none" "a repo with no commit did not say so"
  says err.txt "forward file=gate-verdict.json bytes=" "the verdict file was not named before forwarding"

  # A real commit: its subject is written down, and each id names where it came
  # from, because the two ids can come from two different places.
  git init -q . >/dev/null 2>&1 || true
  git -c user.email=selftest@example.internal -c user.name=selftest \
    commit -q --allow-empty -m 'fix timeout after FIN-471 approval #472' || true
  try env DRY_RUN=1 GITLAB_ISSUE= JIRA_ISSUE= CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/ticket-sync.sh" post
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    says err.txt "commit subject=fix" "the subject that was read is not in the log"
    says err.txt "provenance gitlab=472/commit jira=FIN-471/commit" "the source of the ticket id is not named"
  else
    echo "ticket-sync selftest NOTE: this machine cannot commit in a scratch repo, the commit path is not covered" >&2
  fi

  # An explicit argument outranks the commit, and says so.
  try env DRY_RUN=1 GITLAB_ISSUE=471 JIRA_ISSUE= CI_PROJECT_NAME=core-api \
    bash "$SCRIPT_DIR/ticket-sync.sh" post --jira FIN-900
  says err.txt "provenance gitlab=471/env jira=FIN-900/flag" "an id supplied by hand was not marked as such"

  cd /; rm -rf "$tmp"
  if [ "$fails" = "0" ]; then echo "ticket-sync selftest: ok" >&2; return 0; fi
  echo "ticket-sync selftest: $fails failures" >&2; return 1
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
