#!/usr/bin/env python3
"""Version stamp for one pipeline, plus checks on its two derived artifacts.

Used by the `build:release-stamp` job in every template, and by `scan:sbom-index`
to verify a freshly built SBOM. Stdlib only: a job that needs pip install on top
of a runner image is a job that will fail on a runner with no network access,
and that failure will look like a build failure.

The log line format matches ci-library/scripts/lib/log.sh and run-gate.groovy:
    2026-10-10T23:41:02.118+07:00 INFO build:release-stamp stamped version=R1.4.2

What this file does NOT do:
  - it never touches the network (all data comes from git and the GitLab environment);
  - it never writes the version into the source tree (build-info.json is an artifact, not a commit);
  - it never infers "success" from the absence of errors.
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
    """Local time with offset, three fractional digits, in RFC3339 shape."""
    now = now or datetime.now().astimezone()
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}" + now.strftime("%z")[:3] + ":" + now.strftime("%z")[3:]


def log(level: str, message: str) -> None:
    if _RANK.get(level, -1) < _RANK.get(os.environ.get("LOG_LEVEL", "INFO"), 2):
        return
    print(f"{stamp()} {level} {SCOPE} {message}", file=sys.stderr)


# ── version ──────────────────────────────────────────────────────────────────

TAG_RE = re.compile(r"^(?P<prefix>[A-Z])(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")


def parse_release_tag(tag: str) -> dict | None:
    """`R1.4.2` -> {prefix: R, major: 1, minor: 4, patch: 2}. Any other shape -> None."""
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
    """The version that comes next.

    The bump rule lives in ONE place and is used by every template. If each team
    picked its own rule, `R1.5.0` in one repo and `R1.5.0` in another repo would
    stop meaning anything.
    """
    parsed = parse_release_tag(last_tag or "")
    if not parsed or parsed["prefix"] != prefix:
        return f"{prefix}0.1.0"
    return f"{prefix}{parsed['major']}.{parsed['minor']}.{parsed['patch'] + 1}"


def git(*args: str) -> str:
    """git with trustworthy output: when git fails, we do not guess."""
    try:
        out = subprocess.run(("git",) + args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def describe_commit() -> dict:
    """Commit identity from the repo, not from what the pipeline submitted."""
    sha = os.environ.get("CI_COMMIT_SHA") or git("rev-parse", "HEAD")
    branch = os.environ.get("CI_COMMIT_REF_NAME") or git("rev-parse", "--abbrev-ref", "HEAD")
    tag = os.environ.get("CI_COMMIT_TAG") or ""
    last = git("describe", "--tags", "--abbrev=0", "--match", "[A-Z][0-9]*")
    return {"sha": sha, "branch": branch, "tag": tag, "lastTag": last, "short": sha[:7] if sha else ""}


def render_build_info(prefix: str, commit: dict, artifacts: list[dict], now: datetime | None = None) -> dict:
    """The one place where `status` is computed.

    success = there is a commit AND there are artifacts. No other path leads to
    'success', because this status is what GateResult reads as `deploy.result`.
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


# ── SBOM checks ──────────────────────────────────────────────────────────────

def read_sbom(path: str) -> dict | None:
    """The document itself, or None when it cannot be read.

    The log line is built from what this returns, so a count written to the
    console is a count that was taken out of the file.
    """
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    return doc if isinstance(doc, dict) else None


def sbom_facts(doc: dict) -> dict:
    """What the SBOM says about itself: its shape and how much it inventories."""
    components = doc.get("components") or []
    return {
        "format": doc.get("bomFormat") or "none",
        "specVersion": doc.get("specVersion") or "none",
        "components": len(components),
        "versioned": sum(1 for c in components if isinstance(c, dict) and c.get("name") and c.get("version")),
    }


def verify_sbom(path: str) -> list[str]:
    """Return the list of problems; empty means this SBOM is usable."""
    problems: list[str] = []
    if not os.path.exists(path):
        return [f"sbom: file {path} does not exist"]
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except json.JSONDecodeError as exc:
        return [f"sbom: not valid JSON ({exc.msg})"]
    if doc.get("bomFormat") != "CycloneDX":
        problems.append(f"sbom: bomFormat '{doc.get('bomFormat')}' is not CycloneDX")
    if not doc.get("specVersion"):
        problems.append("sbom: specVersion missing, a consumer cannot tell which shape this is")
    components = doc.get("components") or []
    if not components:
        # This is the main trap: a valid but empty document means "no
        # dependencies", and it reads as clean to anyone who checks the component
        # count without asking where the number came from.
        problems.append("sbom: zero components, this release cannot be inventoried")
    for i, c in enumerate(components):
        if not c.get("name") or not c.get("version"):
            problems.append(f"sbom: component {i} without name or version")
    return problems


# ── config contract ──────────────────────────────────────────────────────────

CONFIG_REQUIRED = {
    "service": str,
    "port": int,
    "healthPath": str,
    "owners": list,
}


def check_config(schema_path: str, docs: list[dict]) -> list[str]:
    """Required keys and their types, without a schema library.

    Enough for a small contract, and that is the point: what needs preventing is
    one team renaming `healthPath` to `health_path` and only finding out in the
    production namespace.
    """
    problems: list[str] = []
    if not os.path.exists(schema_path):
        return [f"config: schema {schema_path} does not exist"]
    with open(schema_path, encoding="utf-8") as fh:
        try:
            required = json.load(fh).get("required") or {}
        except json.JSONDecodeError as exc:
            return [f"config: schema is not valid JSON ({exc.msg})"]
    for doc in docs:
        name = doc.get("service", "?")
        for key in required:
            if key not in doc:
                problems.append(f"config {name}: required key '{key}' missing")
            elif not isinstance(doc[key], CONFIG_REQUIRED.get(key, object)):
                problems.append(f"config {name}: '{key}' has the wrong type {type(doc[key]).__name__}")
        if isinstance(doc.get("port"), int) and not (1024 <= doc["port"] <= 65535):
            problems.append(f"config {name}: port {doc['port']} outside the range that may be used")
    return problems


# ── selftest ────────────────────────────────────────────────────────────────

def selftest() -> int:
    fails: list[str] = []

    def ok(cond: bool, name: str) -> None:
        if not cond:
            fails.append(name)

    ok(parse_release_tag("R1.4.2") == {"prefix": "R", "major": 1, "minor": 4, "patch": 2}, "parse tag")
    ok(parse_release_tag("1.4.2") is None, "a tag without a prefix is refused")
    ok(parse_release_tag("R1.4") is None, "a two-number tag is refused")
    ok(next_version("R1.4.2", "R") == "R1.4.3", "bump patch")
    ok(next_version(None, "W") == "W0.1.0", "no tag = the start")
    ok(next_version("M2.0.0", "W") == "W0.1.0", "another prefix is not counted in")

    info = render_build_info("R", {"sha": "abc1234def", "short": "abc1234", "branch": "main", "tag": "R1.4.2", "lastTag": "R1.4.1"}, [])
    ok(info["status"] == "no result reported", "no artifacts is never success")
    ok(info["version"] == "R1.4.2", "an explicit tag is used as it is")
    with_art = render_build_info("R", {"sha": "abc", "short": "abc", "branch": "main", "tag": "", "lastTag": "R1.4.2"}, [{"path": "a.jar", "exists": True}])
    ok(with_art["status"] == "success", "an artifact present = success")
    ok(with_art["version"] == "R1.4.3", "no tag = bump from the last tag")

    ok(verify_sbom("no-such-file.json") == ["sbom: file no-such-file.json does not exist"], "missing sbom")
    ok(any("zero components" in p for p in verify_sbom_write({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": []})), "empty sbom caught")
    ok(verify_sbom_write({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": [{"name": "jackson", "version": "2.15.0"}]}) == [], "valid sbom passes")
    ok(any("is not CycloneDX" in p for p in verify_sbom_write({"bomFormat": "SPDX", "components": [{"name": "a", "version": "1"}]})), "another format caught")

    ok(any("healthPath" in p for p in check_config_write({"required": {"healthPath": "str"}}, [{"service": "a", "port": 8080, "owners": ["x"]}])), "required key missing")
    ok(any("port" in p for p in check_config_write({"required": {"port": "int"}}, [{"service": "a", "port": 22, "owners": ["x"]}])), "low port refused")
    ok(check_config_write({"required": {"port": "int"}}, [{"service": "a", "port": 8080, "owners": ["x"]}]) == [], "valid config passes")

    # The numbers that go into the log are read out of the document, one by one.
    facts = sbom_facts({"bomFormat": "CycloneDX", "specVersion": "1.6",
                        "components": [{"name": "a", "version": "1"}, {"name": "b"}, {"version": "2"}]})
    ok(facts["components"] == 3, "every component is counted")
    ok(facts["versioned"] == 1, "only a component with a name and a version counts as inventoried")
    ok(facts["specVersion"] == "1.6" and facts["format"] == "CycloneDX", "the spec version is the one that was written")
    ok(read_sbom("file-that-does-not-exist.json") is None, "a file that is not there is not read as an empty document")
    ok(read_sbom_write({"bomFormat": "CycloneDX", "specVersion": "1.5", "components": [{"name": "a", "version": "1"}]}) is not None, "a written sbom is readable")

    line = capture_log(lambda: log("INFO", "stamped version=R1.4.2"))
    ok(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} INFO \S+ stamped version=R1\.4\.2$", line) is not None, "log line shape")

    for f in fails:
        print(f"release_stamp selftest FAIL {f}", file=sys.stderr)
    print("release_stamp selftest: ok" if not fails else f"release_stamp selftest: {len(fails)} failures", file=sys.stderr)
    return 0 if not fails else 1


def read_sbom_write(doc: dict) -> dict | None:
    path = ".selftest-sbom-read.json"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    try:
        return read_sbom(path)
    finally:
        os.unlink(path)


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
    ap.add_argument("--artifact", action="append", default=[], help="path of an artifact that must exist")
    ap.add_argument("--audit-line", action="store_true", help="write one audit line to stderr")
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
        doc = read_sbom(args.verify_sbom)
        if doc is None:
            # Nothing could be counted, so nothing is counted: an absent file is
            # not a document with zero components in it.
            log("WARN", f"sbom file={args.verify_sbom} readable=false")
        else:
            facts = sbom_facts(doc)
            log("INFO", f"sbom read file={args.verify_sbom} format={facts['format']} "
                        f"specVersion={facts['specVersion']} components={facts['components']} versioned={facts['versioned']}")
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
    # Where the version number came from: a tag that exists, or the bump that
    # follows the last one. `none` is written as none, because a missing tag is
    # the fact that makes the first release of a repo read as R0.1.0.
    log("INFO", f"commit branch={commit['branch'] or 'none'} short={commit['short'] or 'none'} "
                f"tag={commit['tag'] or 'none'} lastTag={commit['lastTag'] or 'none'}")
    requested = args.artifact or ["target"]
    artifacts = collect_artifacts(requested)
    present = [a["path"] for a in artifacts if a["exists"]]
    missing = [a["path"] for a in artifacts if not a["exists"]]
    log("INFO", f"artifacts requested={len(requested)} present={len(present)} missing={len(missing)} "
                f"paths={','.join(present) or 'none'}")
    info = render_build_info(args.tag_prefix, commit, artifacts)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(info, fh, indent=2, sort_keys=True)
        fh.write("\n")
    log("INFO", f"stamped version={info['version']} commit={info['commit'] or 'none'} artifacts={len(info['artifacts'])} status={info['status']}")
    log("INFO", f"written file={args.output} bytes={os.path.getsize(args.output)} prefix={info['prefix']} pipeline={info['pipeline']}")
    if args.audit_line:
        # The same one line people will search for in the log aggregator six
        # months from now, written while the release happens.
        log("INFO", f"audit release={info['version']} pipeline={info['pipeline']} branch={info['branch'] or 'none'}")
    print(json.dumps(info, sort_keys=True))
    return 0 if info["status"] == "success" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
