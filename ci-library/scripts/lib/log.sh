#!/bin/bash
# One standard log line for every script the gateway calls.
#
# FORMAT
#   <time> <LEVEL> <scope> <message> [key=value ...]
#   2026-10-10T23:41:02.118+07:00 INFO deploy-sit applying revision=1421 tier=1
#
# The timestamp is RFC3339 with a zone offset, the same shape that
# `gitlab-runner --timestamps` produces, so lines from this script and from the
# runner read as one stream. The Jenkins side uses the Timestamper plugin, which
# prints the same clock as HH:mm:ss.SSS.
#
# Rules these functions hold to:
#   - LEVEL is always one of TRACE DEBUG INFO WARN ERROR, uppercase.
#   - scope = the name of the calling job, set once through log_init.
#   - key=value pairs at the end, with no space inside a value.
#   - log to stderr only; stdout stays free for artifacts (JSON, path, version).
#
# Source this file; do not execute it.

# Numeric levels let log_should_emit get by with one comparison.
__LOG_LEVELS="TRACE DEBUG INFO WARN ERROR"
__LOG_NUM_FOR() { case "$1" in TRACE) echo 0;; DEBUG) echo 1;; INFO) echo 2;; WARN) echo 3;; ERROR) echo 4;; *) echo -1;; esac; }

LOG_SCOPE="${CI_JOB_NAME:-local}"

log_init() {
  LOG_SCOPE="${1:?log_init needs a scope}"
}

# Milliseconds: GNU date has %N, macOS does not. EPOCHREALTIME covers bash 5+.
# When neither is available, the milliseconds print as 000, so the line shape
# does not change silently between the two machines.
log_now() {
  local base offset ms
  base="$(date +%Y-%m-%dT%H:%M:%S)"
  offset="$(date +%z)"
  # RFC3339 wants a colon in the offset; date +%z does not give one.
  offset="${offset:0:3}:${offset:3:2}"
  ms="000"
  if [ -n "${EPOCHREALTIME:-}" ]; then
    ms="${EPOCHREALTIME#*.}"
    ms="${ms:0:3}"
    while [ "${#ms}" -lt 3 ]; do ms="${ms}0"; done
  fi
  printf '%s.%s%s' "$base" "$ms" "$offset"
}

# The threshold is re-read on every call. It used to be cached in a global
# variable, and the selftest caught it: a caller that changed LOG_LEVEL partway
# through kept filtering with the old threshold.
log() {
  local level="$1"; shift
  local num want
  num="$(__LOG_NUM_FOR "$level")"
  if [ "$num" -eq -1 ]; then
    echo "log: unknown level: $level" >&2
    return 2
  fi
  want="$(__LOG_NUM_FOR "${LOG_LEVEL:-INFO}")"
  [ "$num" -lt "$want" ] && return 0
  printf '%s %s %s %s\n' "$(log_now)" "$level" "$LOG_SCOPE" "$*" >&2
}

log_trace() { log TRACE "$*"; }
log_debug() { log DEBUG "$*"; }
log_info()  { log INFO "$*"; }
log_warn()  { log WARN "$*"; }
log_error() { log ERROR "$*"; }

# One greppable failure line: the reason always sits in the same position.
log_fail() {
  local reason="$1"; shift
  log ERROR "failed reason=$reason $*"
}

# Tested, not trusted. Each script's --selftest gate calls this, so a format
# change that breaks the line shape shows up on the developer's own machine.
log_selftest() {
  local line fails=0
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[+-][0-9]{2}:[0-9]{2} (TRACE|DEBUG|INFO|WARN|ERROR) [a-z0-9._-]+ .*$'
  line="$(LOG_SCOPE=selftest log INFO hello key=value 2>&1)"
  printf '%s' "$line" | grep -Eq "$re" || { echo "log_selftest: wrong line shape: $line" >&2; fails=$((fails+1)); }
  case "$line" in *"key=value"*) ;; *) echo "log_selftest: key=value pair missing" >&2; fails=$((fails+1));; esac

  # A level below the threshold must not print.
  line="$(LOG_LEVEL=WARN LOG_SCOPE=selftest log INFO quiet 2>&1)"
  [ -z "$line" ] || { echo "log_selftest: INFO printed even though the threshold is WARN" >&2; fails=$((fails+1)); }
  line="$(LOG_LEVEL=WARN LOG_SCOPE=selftest log ERROR loud 2>&1)"
  case "$line" in *ERROR*) ;; *) echo "log_selftest: ERROR was held back" >&2; fails=$((fails+1));; esac

  # A wrong level has to make noise, not pass quietly.
  if LOG_SCOPE=selftest log BANANA x >/dev/null 2>&1; then
    echo "log_selftest: unknown level was accepted" >&2; fails=$((fails+1))
  fi

  if [ "$fails" -eq 0 ]; then echo "log_selftest: ok" >&2; return 0; fi
  echo "log_selftest: $fails failures" >&2; return 1
}
