#!/bin/bash
# Standar satu baris log untuk semua script yang dipanggil gateway.
#
# FORMAT
#   <waktu> <LEVEL> <scope> <pesan> [kunci=nilai ...]
#   2026-10-10T23:41:02.118+07:00 INFO deploy-sit applying revision=1421 tier=1
#
# Bentuk waktunya RFC3339 dengan offset zona, sama seperti yang dihasilkan
# `gitlab-runner --timestamps`, jadi baris dari script ini dan baris dari runner
# bisa dibaca sebagai satu stream. Sisi Jenkins memakai plugin Timestamper yang
# mencetak jam yang sama dalam bentuk HH:mm:ss.SSS.
#
# Aturan yang dijaga fungsi ini:
#   - LEVEL selalu salah satu dari TRACE DEBUG INFO WARN ERROR, huruf besar.
#   - scope = nama job yang memanggil, di-set sekali lewat log_init.
#   - pasangan kunci=nilai di ujung, tanpa spasi di dalam nilai.
#   - semuanya ke stderr; stdout tetap bebas untuk artefak (JSON, path, versi).
#
# File ini di-source, tidak dieksekusi.

# Level numerik dipakai log_should_emit supaya satu perbandingan cukup.
__LOG_LEVELS="TRACE DEBUG INFO WARN ERROR"
__LOG_NUM_FOR() { case "$1" in TRACE) echo 0;; DEBUG) echo 1;; INFO) echo 2;; WARN) echo 3;; ERROR) echo 4;; *) echo -1;; esac; }

LOG_SCOPE="${CI_JOB_NAME:-local}"

log_init() {
  LOG_SCOPE="${1:?log_init butuh scope}"
}

# Milidetik: GNU date punya %N, macOS tidak. EPOCHREALTIME ada di bash 5+.
# Kalau keduanya tidak ada, milidetik ditulis 000 supaya bentuk barisnya tidak
# berubah diam-diam antara dua mesin.
log_now() {
  local base offset ms
  base="$(date +%Y-%m-%dT%H:%M:%S)"
  offset="$(date +%z)"
  # RFC3339 menuntut tanda titik dua di offset; date +%z tidak memberikannya.
  offset="${offset:0:3}:${offset:3:2}"
  ms="000"
  if [ -n "${EPOCHREALTIME:-}" ]; then
    ms="${EPOCHREALTIME#*.}"
    ms="${ms:0:3}"
    while [ "${#ms}" -lt 3 ]; do ms="${ms}0"; done
  fi
  printf '%s.%s%s' "$base" "$ms" "$offset"
}

# Ambang dibaca ulang setiap panggilan. Pernah di-cache di variabel global, dan
# selftest menangkapnya: caller yang mengubah LOG_LEVEL di tengah jalan masih
# menyaring dengan ambang lama.
log() {
  local level="$1"; shift
  local num want
  num="$(__LOG_NUM_FOR "$level")"
  if [ "$num" -eq -1 ]; then
    echo "log: level tidak dikenal: $level" >&2
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

# Satu baris kegagalan yang bisa dicari: alasannya selalu di posisi yang sama.
log_fail() {
  local reason="$1"; shift
  log ERROR "failed reason=$reason $*"
}

# Diuji, bukan dipercaya. Gerbang --selftest di tiap script memanggil ini, jadi
# perubahan format yang merusak bentuk baris ketahuan di mesin pengembang.
log_selftest() {
  local line fails=0
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[+-][0-9]{2}:[0-9]{2} (TRACE|DEBUG|INFO|WARN|ERROR) [a-z0-9._-]+ .*$'
  line="$(LOG_SCOPE=selftest log INFO hello key=value 2>&1)"
  printf '%s' "$line" | grep -Eq "$re" || { echo "log_selftest: bentuk baris salah: $line" >&2; fails=$((fails+1)); }
  case "$line" in *"key=value"*) ;; *) echo "log_selftest: pasangan kunci=nilai hilang" >&2; fails=$((fails+1));; esac

  # Level di bawah ambang tidak boleh tercetak.
  line="$(LOG_LEVEL=WARN LOG_SCOPE=selftest log INFO quiet 2>&1)"
  [ -z "$line" ] || { echo "log_selftest: INFO lolos padahal ambang WARN" >&2; fails=$((fails+1)); }
  line="$(LOG_LEVEL=WARN LOG_SCOPE=selftest log ERROR loud 2>&1)"
  case "$line" in *ERROR*) ;; *) echo "log_selftest: ERROR tertahan" >&2; fails=$((fails+1));; esac

  # Level salah harus bunyi, bukan diam-diam lolos.
  if LOG_SCOPE=selftest log BANANA x >/dev/null 2>&1; then
    echo "log_selftest: level tak dikenal diterima" >&2; fails=$((fails+1))
  fi

  if [ "$fails" -eq 0 ]; then echo "log_selftest: ok" >&2; return 0; fi
  echo "log_selftest: $fails kegagalan" >&2; return 1
}
