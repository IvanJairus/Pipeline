#!/usr/bin/env bash
# Gate: make sure no internal identifier gets pushed out with the code.
# sanitize.py uses the same patterns; if this gate fails, do not push.
#
# 2026-10-10: this gate passed while leaving 48 mappings of
# "service name -> GitLab project ID" in ci-library/gateway.yml on the
# public repo. The old deny-list only recognised organisation names, not the
# mapping pattern. So there is now a --selftest: the synthetic leak sample
# must be caught, and one line getting through means the gate is dead.
set -uo pipefail
# A cd that fails without || exit makes every pattern search run in the wrong
# directory, and a gate that checks the wrong directory always passes.
cd "$(dirname "$0")/.." || { echo "check-sanitised: cannot enter the repo root" >&2; exit 2; }
fail=0

# Pure ERE. (?i) is not a POSIX extension: its behaviour differs between BSD
# grep on the laptop and GNU grep on the runner, so capitalisation is written out.
P_HOSTNAME='\.(co\.id|intra|corp)\b'
P_IP='(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}'
# What may pass: the synthetic 10.20.x range and loopback. Loopback is not an
# internal identifier, it is the address of the machine running the test, and
# hiding it would only force people to write "localhost" in code that
# really does call 127.0.0.1.
P_IP_SYNTH='(^|\.)(10\.20|127\.0)(\.[0-9]+){2}$'
P_KRED="(token|password|secret|api[_-]?key)[\"' ]*[:=][\"' ]*[A-Za-z0-9._+/=-]{12,}[\"']"
P_BEARER='([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[A-Za-z0-9._+/=-]{16,}'
# No organisation name or service name list lives in this file. A deny-list that
# names internal vocabulary publishes exactly the vocabulary it means to guard, and
# an explaining comment becomes part of the leak. What may stay is structural
# checking: an invalid shape is always wrong, whatever it is called. Organisation
# vocabulary lives in the private file that CI reads, not here.
P_PAT='glpat-[A-Za-z0-9_-]{8,}|github_pat_[A-Za-z0-9_]{10,}'
# This is what was missing before: a service name carrying a GitLab ID, and an internal project path.
# Same as the IP rule, a synthetic ID band is allowed: 1000-1999. Without it the
# samples that are intentionally synthetic get flagged too, and a gate that keeps
# shouting is a gate people turn off.
P_ID_MAP='[a-z][a-z0-9_-]*\([0-9]{4,6}\)'
P_ID_SYNTH='\(1[0-9]{3}\)$'
# An allow-list, not a deny-list: the only valid `project:` value in this repo.
P_PROJ_ALLOW='^platform/pipeline-gateway$'
# The ID also appears bare on rules lines, not only in the comment column. Without this,
# a sanitised result that only edited the comments still passes.
P_PROJID='CI_PROJECT_ID == "[0-9]{4,6}"'
P_PROJID_SYNTH='"1[0-9]{3}"'

scan() {
  local label="$1" regex="$2" hits
  local -a extra=()
  # The name patterns used to be case-sensitive, so an uppercase "BNI" got through. For
  # vocabulary checks, capitalisation must not be an excuse.
  [ "${3:-}" = "-i" ] && extra+=("-i")
  hits=$(grep -rnEI "${extra[@]}" --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$regex" . || true)
  if [ -n "$hits" ]; then
    echo "::error::$label found"
    printf '%s\n' "$hits" | head -5
    fail=1
  else
    echo "ok: $label clean"
  fi
}

ip_hits() {
  # A raw output line still carries the non-numeric prefix from P_IP ("svc 10.20.4.7"),
  # so the prefix is stripped first. Without that step an address the band filter
  # should release gets through as text that does not look like an address at all.
  grep -rhoEI --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$P_IP" . 2>/dev/null \
    | sed -E 's/^[^0-9]*//' | tr -d ' :' | grep -vE "$P_IP_SYNTH" | sort -u
}

projid_hits() {
  grep -rhoEI --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$P_PROJID" . 2>/dev/null \
    | sort -u | grep -vE "$P_PROJID_SYNTH"
}

id_map_hits() {
  grep -rhoEI --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$P_ID_MAP" . 2>/dev/null \
    | sort -u | grep -vE "$P_ID_SYNTH"
}

selftest() {
  local dir rc=0 probe
  dir=$(mktemp -d) || return 1
  trap 'rm -rf "$dir"' RETURN
  cat > "$dir/sample" <<'BAD'
# all values below are fictional; what makes them bad is their shape, not their name
platform Backend services
  - svc-one(20001), svc-two(20002), svc-three(20003)
  - svc-four(20004), svc-five(20005), svc-six(20006)
      - if: $CI_PROJECT_ID == "20007"
include:
  - project: 'team/private-gateway'
    ref: master
Authorization: Bearer Zm9vYmFyYmF6c2VjcmV0MTIzNDU2Nzg5MAo=
token = "aB3dE5fG7hI9jK1lM3nO"
glpat-AbCdEfGhIjKlMnOpQrSt
host: gitlab.internal.corp
BAD
  for probe in "service name mapped to an ID:$P_ID_MAP" \
               "bare project ID:$P_PROJID" \
               "Bearer/Basic literal:$P_BEARER" \
               "literal credential:$P_KRED" "glpat / PAT:$P_PAT" "internal hostname:$P_HOSTNAME"; do
    label=${probe%%:*}; regex=${probe#*:}
    if grep -qiE "$regex" "$dir/sample"; then
      echo "  ok   caught: $label"
    else
      echo "  DEAD: $label did not catch the leak sample"
      rc=1
    fi
  done
  # the project: allow-list is tested separately; it is a pipeline of steps, not one regex.
  strip() { grep -oE "project: *'[^']+'" | sed -E "s/project: *'//; s/'$//"; }
  badv=$(printf "  - project: 'team/private-gateway'\n" | strip | grep -vE "$P_PROJ_ALLOW" || true)
  goodv=$(printf "  - project: 'platform/pipeline-gateway'\n" | strip | grep -vE "$P_PROJ_ALLOW" || true)
  if [ -n "$badv" ] && [ -z "$goodv" ]; then
    echo "  ok   a project: value outside the allow-list is caught, the allowed one gets through"
  else
    echo "  DEAD: the project: allow-list check is not working (bad='$badv' good='$goodv')"
    rc=1
  fi

  # and the other way round: a synthetic sample must not raise an alarm. If the alarm
  # is always on, this gate is only noise that people will turn off.
  printf '  - api(1001), web(1002)\n  - if: $CI_PROJECT_ID == "1001"\n  - project: %s\n' "'platform/pipeline-gateway'" > "$dir/clean"
  over_map=$(grep -oE "$P_ID_MAP" "$dir/clean" | grep -vE "$P_ID_SYNTH" || true)
  over_pjid=$(grep -oE "$P_PROJID" "$dir/clean" | grep -vE "$P_PROJID_SYNTH" || true)
  over_proj=$(grep -oE "project: *'[^']+'" "$dir/clean" | sed -E "s/project: *'//; s/'$//" | grep -vE "$P_PROJ_ALLOW" || true)
  if [ -n "$over_map$over_pjid$over_proj" ]; then
    echo "  TOO EAGER: a synthetic sample got flagged ($over_map$over_pjid$over_proj)"
    rc=1
  else
    echo "  ok   synthetic samples (api(1001), rules 1001, an allowed project) were not flagged"
  fi

  # synthetic band: the pattern must still recognise the shape, then the band filter
  # releases it. If neither works, something getting through is not a sign of safety.
  if grep -qE "$P_ID_MAP" "$dir/clean" && [ -z "$over_map" ]; then
    echo "  ok   the synthetic ID is matched by the pattern, then released by the band filter"
  else
    echo "  DEAD: the synthetic ID band filter is not working"
    rc=1
  fi
  if grep -qE "$P_PROJID" "$dir/clean" && [ -z "$over_pjid" ]; then
    echo "  ok   a synthetic project ID on a rules line is matched, then released by the band filter"
  else
    echo "  DEAD: the project ID band filter is not working"
    rc=1
  fi

  # The IP band filter is tested both ways too: an internal address of real shape must
  # stay, the synthetic range and loopback must be released.
  printf 'svc 10.20.4.7 and 127.0.0.1 and 172.16.9.4\n' > "$dir/ips"
  over_ip=$(grep -oE "$P_IP" "$dir/ips" | sed -E 's/^[^0-9]*//' | tr -d ' :' | grep -vE "$P_IP_SYNTH" || true)
  hit_ip=$(grep -cE "$P_IP" "$dir/ips" || true)
  if [ "$hit_ip" != "0" ] && [ "$over_ip" = "172.16.9.4" ]; then
    echo "  ok   the IP band filter releases 10.20.x and loopback, and holds the rest"
  else
    echo "  DEAD: the IP band filter is not working (hits=$hit_ip left='$over_ip')"
    rc=1
  fi
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

scan "internal hostname"     "$P_HOSTNAME"
left=$(ip_hits || true)
if [ -n "$left" ]; then echo "::error::a non-synthetic IP was found"; printf '%s\n' "$left" | head -5; fail=1
else echo "ok: IP, only the synthetic 10.20.x range"; fi
scan "literal credential"    "$P_KRED"
scan "Bearer/Basic literal"  "$P_BEARER"

scan "glpat / PAT"           "$P_PAT"
idl=$(id_map_hits || true)
if [ -n "$idl" ]; then echo "::error::a service name mapped to a real project ID was found"; printf '%s\n' "$idl" | head -8; fail=1
else echo "ok: name to project ID mapping, only the synthetic 1000-1999 band"; fi
# any project: value other than the allowed one means an internal path went public
pj_bad=$(grep -rhoE --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh \
  "project: *'[^']+'|project: *\"[a-z0-9._/-]+\"" . 2>/dev/null \
  | sed -E "s/project: *['\"]([^'\"]+)['\"]/\1/" | sort -u | grep -vE "$P_PROJ_ALLOW" || true)
if [ -n "$pj_bad" ]; then echo "::error::a project: value outside the allow-list"; printf '%s\n' "$pj_bad" | head -5; fail=1
else echo "ok: project: values, only the allow-list appears"; fi
pj=$(projid_hits || true)
if [ -n "$pj" ]; then echo "::error::a real project ID was found on a rules line"; printf '%s\n' "$pj" | head -8; fail=1
else echo "ok: project IDs on rules lines, only the synthetic 1000-1999 band"; fi
exit $fail
