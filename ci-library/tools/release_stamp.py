#!/usr/bin/env python3
"""Version stamp untuk satu pipeline, dan pemeriksaan dua artefak turunannya.

Dipakai oleh job `build:release-stamp` di semua template, dan oleh `scan:sbom-index`
untuk memverifikasi SBOM yang baru dibuat. Hanya stdlib: sebuah job yang butuh
pip install di atas image runner adalah job yang akan gagal di runner yang tidak
punya akses jaringan, dan kegagalan itu akan terlihat seperti kegagalan build.

Format baris log sama dengan ci-library/scripts/lib/log.sh dan run-gate.groovy:
    2026-10-10T23:41:02.118+07:00 INFO build:release-stamp stamped version=R1.4.2

Yang TIDAK dilakukan file ini:
  - tidak menyentuh jaringan (semua data dari git dan environment GitLab);
  - tidak menulis versi ke source tree (build-info.json adalah artefak, bukan commit);
  - tidak pernah menyimpulkan "sukses" dari tidak adanya error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

# ── log ─────────────────────────────────────────────────────────────────────

LEVELS = ("TRACE", "DEBUG", "INFO", "WARN", "ERROR")
_RANK = {name: i for i, name in enumerate(LEVELS)}

SCOPE = os.environ.get("CI_JOB_NAME") or "release-stamp"


def stamp(now: datetime | None = None) -> str:
    """Waktu lokal dengan offset, tiga digit desimal, sesuai bentuk RFC3339."""
    now = now or datetime.now().astimezone()
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}" + now.strftime("%z")[:3] + ":" + now.strftime("%z")[3:]


def log(level: str, message: str) -> None:
    if _RANK.get(level, -1) < _RANK.get(os.environ.get("LOG_LEVEL", "INFO"), 2):
        return
    print(f"{stamp()} {level} {SCOPE} {message}", file=sys.stderr)


# ── versi ───────────────────────────────────────────────────────────────────

TAG_RE = re.compile(r"^(?P<prefix>[A-Z])(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")


def parse_release_tag(tag: str) -> dict | None:
    """`R1.4.2` -> {prefix: R, major: 1, minor: 4, patch: 2}. Bentuk lain -> None."""
    m = TAG_RE.match(tag or "")
    if not m:
        return None
    return {
        "prefix": m.group("prefix"),
        "major": int(m.group("major")),
        "minor": int(m.group("minor")),
        "patch": int(m.group("patch")),
    }


def next_version(last_tag: str | None, prefix: str) -> str:
    """Versi yang akan datang.

    Aturan bump ada di SATU tempat dan dipakai semua template. Kalau tiap tim
    memilih aturannya sendiri, `R1.5.0` di satu repo dan `R1.5.0` di repo lain
    berhenti berarti apa-apa.
    """
    parsed = parse_release_tag(last_tag or "")
    if not parsed or parsed["prefix"] != prefix:
        return f"{prefix}0.1.0"
    return f"{prefix}{parsed['major']}.{parsed['minor']}.{parsed['patch'] + 1}"


def git(*args: str) -> str:
    """git dengan hasil yang bisa dipercaya: kalau git gagal, kita tidak menebak."""
    try:
        out = subprocess.run(("git",) + args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def describe_commit() -> dict:
    """Identitas commit dari repo, bukan dari apa yang dikirim pipeline."""
    sha = os.environ.get("CI_COMMIT_SHA") or git("rev-parse", "HEAD")
    branch = os.environ.get("CI_COMMIT_REF_NAME") or git("rev-parse", "--abbrev-ref", "HEAD")
    tag = os.environ.get("CI_COMMIT_TAG") or ""
    last = git("describe", "--tags", "--abbrev=0", "--match", "[A-Z][0-9]*")
    return {"sha": sha, "branch": branch, "tag": tag, "lastTag": last, "short": sha[:7] if sha else ""}


def render_build_info(prefix: str, commit: dict, artifacts: list[dict], now: datetime | None = None) -> dict:
    """Satu-satunya tempat `status` dihitung.

    sukses = ada commit DAN ada artefak. Tidak ada jalur lain menuju 'success',
    karena status inilah yang dibaca GateResult sebagai `deploy.result`.
    """
    version = commit["tag"] if commit["tag"] else next_version(commit["lastTag"], prefix)
    present = [a for a in artifacts if a.get("exists")]
    return {
        "version": version,
        "prefix": prefix,
        "commit": commit["short"],
        "branch": commit["branch"],
        "pipeline": os.environ.get("CI_PIPELINE_ID", "local"),
        "builtAt": stamp(now),
        "artifacts": present,
        "status": "success" if commit["sha"] and present else "no result reported",
    }


def collect_artifacts(paths: list[str]) -> list[dict]:
    out = []
    for p in paths:
        exists = os.path.exists(p)
        out.append({"path": p, "exists": exists, "bytes": os.path.getsize(p) if exists else 0})
    return out


# ── pemeriksaan SBOM ────────────────────────────────────────────────────────

def verify_sbom(path: str) -> list[str]:
    """Kembalikan daftar masalah; kosong berarti SBOM ini bisa dipakai."""
    problems: list[str] = []
    if not os.path.exists(path):
        return [f"sbom: berkas {path} tidak ada"]
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except json.JSONDecodeError as exc:
        return [f"sbom: bukan JSON yang sah ({exc.msg})"]
    if doc.get("bomFormat") != "CycloneDX":
        problems.append(f"sbom: bomFormat '{doc.get('bomFormat')}' bukan CycloneDX")
    if not doc.get("specVersion"):
        problems.append("sbom: specVersion hilang, konsumen tidak bisa tahu bentuknya")
    components = doc.get("components") or []
    if not components:
        # Ini jebakan utamanya: dokumen yang sah tapi kosong berarti "tidak ada
        # dependency", dan itu terbaca bersih oleh siapa pun yang hanya cek
        # jumlah komponen tanpa melihat dari mana angkanya datang.
        problems.append("sbom: nol komponen, ini release yang tidak bisa diinventarisasi")
    for i, c in enumerate(components):
        if not c.get("name") or not c.get("version"):
            problems.append(f"sbom: komponen ke-{i} tanpa name atau version")
    return problems


# ── kontrak konfigurasi ─────────────────────────────────────────────────────

CONFIG_REQUIRED = {
    "service": str,
    "port": int,
    "healthPath": str,
    "owners": list,
}


def check_config(schema_path: str, docs: list[dict]) -> list[str]:
    """Kunci wajib dan tipenya, tanpa library skema.

    Cukup untuk kontrak kecil, dan itu memang tujuannya: yang perlu dicegah
    adalah satu tim mengganti `healthPath` jadi `health_path` dan baru tahu di
    namespace produksi.
    """
    problems: list[str] = []
    if not os.path.exists(schema_path):
        return [f"config: skema {schema_path} tidak ada"]
    with open(schema_path, encoding="utf-8") as fh:
        try:
            required = json.load(fh).get("required") or {}
        except json.JSONDecodeError as exc:
            return [f"config: skema bukan JSON sah ({exc.msg})"]
    for doc in docs:
        name = doc.get("service", "?")
        for key in required:
            if key not in doc:
                problems.append(f"config {name}: kunci wajib '{key}' hilang")
            elif not isinstance(doc[key], CONFIG_REQUIRED.get(key, object)):
                problems.append(f"config {name}: '{key}' bertipe {type(doc[key]).__name__}")
        if isinstance(doc.get("port"), int) and not (1024 <= doc["port"] <= 65535):
            problems.append(f"config {name}: port {doc['port']} di luar rentang yang boleh dipakai")
    return problems


# ── selftest ────────────────────────────────────────────────────────────────

def selftest() -> int:
    fails: list[str] = []

    def ok(cond: bool, name: str) -> None:
        if not cond:
            fails.append(name)

    ok(parse_release_tag("R1.4.2") == {"prefix": "R", "major": 1, "minor": 4, "patch": 2}, "parse tag")
    ok(parse_release_tag("1.4.2") is None, "tag tanpa prefix ditolak")
    ok(parse_release_tag("R1.4") is None, "tag dua angka ditolak")
    ok(next_version("R1.4.2", "R") == "R1.4.3", "bump patch")
    ok(next_version(None, "W") == "W0.1.0", "tanpa tag = awal")
    ok(next_version("M2.0.0", "W") == "W0.1.0", "prefix lain tidak ikut dihitung")

    info = render_build_info("R", {"sha": "abc1234def", "short": "abc1234", "branch": "main", "tag": "R1.4.2", "lastTag": "R1.4.1"}, [])
    ok(info["status"] == "no result reported", "tanpa artefak tidak pernah success")
    ok(info["version"] == "R1.4.2", "tag eksplisit dipakai apa adanya")
    with_art = render_build_info("R", {"sha": "abc", "short": "abc", "branch": "main", "tag": "", "lastTag": "R1.4.2"}, [{"path": "a.jar", "exists": True}])
    ok(with_art["status"] == "success", "artefak ada = success")
    ok(with_art["version"] == "R1.4.3", "tanpa tag = bump dari tag terakhir")

    ok(verify_sbom("tidak-ada.json") == ["sbom: berkas tidak-ada.json tidak ada"], "sbom hilang")
    ok(any("nol komponen" in p for p in verify_sbom_write({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": []})), "sbom kosong tertangkap")
    ok(verify_sbom_write({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": [{"name": "jackson", "version": "2.15.0"}]}) == [], "sbom sah lolos")
    ok(any("bukan CycloneDX" in p for p in verify_sbom_write({"bomFormat": "SPDX", "components": [{"name": "a", "version": "1"}]})), "format lain tertangkap")

    ok(any("healthPath" in p for p in check_config_write({"required": {"healthPath": "str"}}, [{"service": "a", "port": 8080, "owners": ["x"]}])), "kunci wajib hilang")
    ok(any("port" in p for p in check_config_write({"required": {"port": "int"}}, [{"service": "a", "port": 22, "owners": ["x"]}])), "port rendah tertolak")
    ok(check_config_write({"required": {"port": "int"}}, [{"service": "a", "port": 8080, "owners": ["x"]}]) == [], "config sah lolos")

    line = capture_log(lambda: log("INFO", "stamped version=R1.4.2"))
    ok(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} INFO \S+ stamped version=R1\.4\.2$", line) is not None, "bentuk baris log")

    for f in fails:
        print(f"release_stamp selftest FAIL {f}", file=sys.stderr)
    print("release_stamp selftest: ok" if not fails else f"release_stamp selftest: {len(fails)} kegagalan", file=sys.stderr)
    return 0 if not fails else 1


def verify_sbom_write(doc: dict) -> list[str]:
    path = ".selftest-sbom.json"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    try:
        return verify_sbom(path)
    finally:
        os.unlink(path)


def check_config_write(schema: dict, docs: list[dict]) -> list[str]:
    path = ".selftest-schema.json"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(schema, fh)
    try:
        return check_config(path, docs)
    finally:
        os.unlink(path)


def capture_log(fn) -> str:
    import io
    from contextlib import redirect_stderr

    buf = io.StringIO()
    with redirect_stderr(buf):
        fn()
    return buf.getvalue().strip()


# ── main ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tag-prefix", default="R")
    ap.add_argument("--output", default="build-info.json")
    ap.add_argument("--artifact", action="append", default=[], help="path artefak yang harus ada")
    ap.add_argument("--audit-line", action="store_true", help="tulis satu baris audit ke stderr")
    ap.add_argument("--verify-sbom", metavar="FILE")
    ap.add_argument("--check-config", metavar="SCHEMA")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if args.verify_sbom:
        problems = verify_sbom(args.verify_sbom)
        for p in problems:
            log("ERROR", f"failed reason=sbom_invalid {p}")
        log("INFO" if not problems else "WARN", f"verify-sbom file={args.verify_sbom} problems={len(problems)}")
        return 1 if problems else 0

    if args.check_config:
        docs = []
        for name in sorted(os.listdir(os.path.dirname(args.check_config) or ".")):
            if name.endswith(".json") and name != os.path.basename(args.check_config):
                with open(os.path.join(os.path.dirname(args.check_config) or ".", name), encoding="utf-8") as fh:
                    loaded = json.load(fh)
                docs.append(loaded if isinstance(loaded, dict) else {"service": name, "documents": loaded})
        problems = check_config(args.check_config, docs)
        for p in problems:
            log("ERROR", f"failed reason=config_contract {p}")
        log("INFO" if not problems else "WARN", f"check-config files={len(docs)} problems={len(problems)}")
        return 1 if problems else 0

    commit = describe_commit()
    artifacts = collect_artifacts(args.artifact or ["target"])
    info = render_build_info(args.tag_prefix, commit, artifacts)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(info, fh, indent=2, sort_keys=True)
        fh.write("\n")
    log("INFO", f"stamped version={info['version']} commit={info['commit'] or 'none'} artifacts={len(info['artifacts'])} status={info['status']}")
    if args.audit_line:
        # Satu baris yang sama yang akan dicari orang di agregator log enam
        # bulan dari sekarang, ditulis saat release-nya terjadi.
        log("INFO", f"audit release={info['version']} pipeline={info['pipeline']} branch={info['branch'] or 'none'}")
    print(json.dumps(info, sort_keys=True))
    return 0 if info["status"] == "success" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
