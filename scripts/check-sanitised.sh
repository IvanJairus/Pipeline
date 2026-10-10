#!/usr/bin/env bash
# Gerbang: pastikan tidak ada identifier internal yang ikut terkirim.
# Pola yang sama dipakai sanitize.py; kalau ini gagal, jangan push.
#
# 2026-10-10: gerbang ini pernah lolos sambil meninggalkan 48 pemetaan
# "nama service -> project ID GitLab" di ci-library/gateway.yml pada repo
# publik. Deny-list lama hanya mengenali nama organisasi, bukan pola
# pemetaan. Jadi sekarang ada --selftest: contoh bocoran sintetis harus
# tertangkap, satu saja yang lolos berarti gerbangnya mati.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# ERE murni. (?i) bukan perluasan POSIX: perilakunya beda antara BSD grep di
# laptop dan GNU grep di runner, jadi kapital ditulis eksplisit.
P_HOSTNAME='\.(co\.id|intra|corp)\b'
P_IP='(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}'
P_IP_SYNTH='(^|\.)10\.20\.[0-9]+\.[0-9]+$'
P_KRED="(token|password|secret|api[_-]?key)[\"' ]*[:=][\"' ]*[A-Za-z0-9._+/=-]{12,}"
P_BEARER='([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[A-Za-z0-9._+/=-]{16,}'
# Tidak ada daftar nama organisasi atau nama service di file ini. Sebuah deny-list
# yang menyebut kosakata internal menerbitkan persis kosakata yang mau dijaganya;
# komentar penjelas pun ikut jadi bagian bocoran. Yang boleh tinggal pemeriksaan
# struktural: bentuk yang tidak sah selalu salah, apa pun namanya. Kosakata
# organisasi hidup di berkas privat yang dibacakan CI, bukan di sini.
P_PAT='glpat-[A-Za-z0-9_-]{8,}|github_pat_[A-Za-z0-9_]{10,}'
# Ini yang dulu tidak ada: nama service yang diberi ID GitLab, dan jalur project internal.
# Sama seperti aturan IP, ada pita ID sintetis yang diizinkan: 1000-1999. Tanpa itu
# contoh yang memang sengaja sintetis akan ikut ditandai, dan gerbang yang berteriak
# terus akan dimatikan orang.
P_ID_MAP='[a-z][a-z0-9_-]*\([0-9]{4,6}\)'
P_ID_SYNTH='\(1[0-9]{3}\)$'
# Allow-list, bukan deny-list: satu-satunya nilai `project:` yang sah di repo ini.
P_PROJ_ALLOW='^platform/pipeline-gateway$'
# ID juga muncul telanjang di baris rules, bukan cuma di kolom komentar. Tanpa ini,
# hasil pembersihan yang hanya mengedit komentar tetap lolos.
P_PROJID='CI_PROJECT_ID == "[0-9]{4,6}"'
P_PROJID_SYNTH='"1[0-9]{3}"'

scan() {
  local label="$1" regex="$2" hits
  local -a extra=()
  # Pola nama dulu case-sensitive, jadi "BNI" huruf besar lolos. Untuk pemeriksaan
  # kosakata, kapital tidak boleh jadi alasan.
  [ "${3:-}" = "-i" ] && extra+=("-i")
  hits=$(grep -rnEI "${extra[@]}" --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$regex" . || true)
  if [ -n "$hits" ]; then
    echo "::error::$label ditemukan"
    printf '%s\n' "$hits" | head -5
    fail=1
  else
    echo "ok: $label bersih"
  fi
}

ip_hits() {
  grep -rhoEI --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh "$P_IP" . 2>/dev/null \
    | tr -d ' :' | grep -vE "$P_IP_SYNTH" | sort -u
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
# semua nilai di bawah fiktif; yang membuatnya buruk adalah bentuknya, bukan namanya
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
  for probe in "pemetaan nama ke ID:$P_ID_MAP" \
               "ID project telanjang:$P_PROJID" \
               "Bearer/Basic literal:$P_BEARER" \
               "kredensial literal:$P_KRED" "glpat / PAT:$P_PAT" "hostname internal:$P_HOSTNAME"; do
    label=${probe%%:*}; regex=${probe#*:}
    if grep -qiE "$regex" "$dir/sample"; then
      echo "  ok   tangkap: $label"
    else
      echo "  MATI: $label tidak menangkap contoh bocoran"
      rc=1
    fi
  done
  # allow-list project: diuji terpisah, ia pipeline bukan satu regex.
  strip() { grep -oE "project: *'[^']+'" | sed -E "s/project: *'//; s/'$//"; }
  badv=$(printf "  - project: 'team/private-gateway'\n" | strip | grep -vE "$P_PROJ_ALLOW" || true)
  goodv=$(printf "  - project: 'platform/pipeline-gateway'\n" | strip | grep -vE "$P_PROJ_ALLOW" || true)
  if [ -n "$badv" ] && [ -z "$goodv" ]; then
    echo "  ok   nilai project: di luar allow-list tertangkap, yang sah lolos"
  else
    echo "  MATI: pemeriksaan allow-list project: tidak bekerja (bad='$badv' good='$goodv')"
    rc=1
  fi

  # dan sebaliknya: contoh sintetis tidak boleh memicu alarm. Kalau alarm selalu
  # menyala, gerbang ini cuma noise yang akan dimatikan orang.
  printf '  - api(1001), web(1002)\n  - if: $CI_PROJECT_ID == "1001"\n  - project: %s\n' "'platform/pipeline-gateway'" > "$dir/clean"
  over_map=$(grep -oE "$P_ID_MAP" "$dir/clean" | grep -vE "$P_ID_SYNTH" || true)
  over_pjid=$(grep -oE "$P_PROJID" "$dir/clean" | grep -vE "$P_PROJID_SYNTH" || true)
  over_proj=$(grep -oE "project: *'[^']+'" "$dir/clean" | sed -E "s/project: *'//; s/'$//" | grep -vE "$P_PROJ_ALLOW" || true)
  if [ -n "$over_map$over_pjid$over_proj" ]; then
    echo "  TERLALU LAPAR: contoh sintetis ikut ditandai ($over_map$over_pjid$over_proj)"
    rc=1
  else
    echo "  ok   contoh sintetis (api(1001), rules 1001, project sah) tidak ditandai"
  fi

  # pita sintetis: polanya harus tetap mengenali bentuknya, baru band-filter
  # melepaskannya. Kalau keduanya tidak bekerja, yang lolos bukan tanda aman.
  if grep -qE "$P_ID_MAP" "$dir/clean" && [ -z "$over_map" ]; then
    echo "  ok   ID sintetis dikenali polanya lalu dilepas band-filter"
  else
    echo "  MATI: band-filter ID sintetis tidak bekerja"
    rc=1
  fi
  if grep -qE "$P_PROJID" "$dir/clean" && [ -z "$over_pjid" ]; then
    echo "  ok   ID project sintetis di baris rules dikenali lalu dilepas band-filter"
  else
    echo "  MATI: band-filter ID project tidak bekerja"
    rc=1
  fi
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

scan "hostname internal"     "$P_HOSTNAME"
left=$(ip_hits || true)
if [ -n "$left" ]; then echo "::error::IP non-sintetis ditemukan"; printf '%s\n' "$left" | head -5; fail=1
else echo "ok: IP, hanya rentang sintetis 10.20.x"; fi
scan "kredensial literal"    "$P_KRED"
scan "Bearer/Basic literal"  "$P_BEARER"

scan "glpat / PAT"           "$P_PAT"
idl=$(id_map_hits || true)
if [ -n "$idl" ]; then echo "::error::pemetaan nama service ke project ID nyata ditemukan"; printf '%s\n' "$idl" | head -8; fail=1
else echo "ok: pemetaan nama ke project ID, hanya pita sintetis 1000-1999"; fi
# nilai project: apa pun selain yang diizinkan berarti jalur internal ikut tayang
pj_bad=$(grep -rhoE --exclude-dir=.git --exclude-dir=_raw --exclude=check-sanitised.sh \
  "project: *'[^']+'|project: *\"[a-z0-9._/-]+\"" . 2>/dev/null \
  | sed -E "s/project: *['\"]([^'\"]+)['\"]/\1/" | sort -u | grep -vE "$P_PROJ_ALLOW" || true)
if [ -n "$pj_bad" ]; then echo "::error::nilai project: di luar allow-list"; printf '%s\n' "$pj_bad" | head -5; fail=1
else echo "ok: nilai project:, hanya allow-list yang muncul"; fi
pj=$(projid_hits || true)
if [ -n "$pj" ]; then echo "::error::ID project nyata di baris rules ditemukan"; printf '%s\n' "$pj" | head -8; fail=1
else echo "ok: ID project di baris rules, hanya pita sintetis 1000-1999"; fi
exit $fail
