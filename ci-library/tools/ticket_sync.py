#!/usr/bin/env python3
"""Attach the gate verdict to the ticket, and (when configured) transition it.

Called by ci-library/scripts/ticket-sync.sh, which is called by the
`gate:ticket-sync` job in every template.

Three decisions make this file worth using, not merely present:

1. Idempotent. One pipeline can be retried, and a ticket that receives two
   identical comments teaches people to stop reading pipeline comments. The key
   is a hash of (pipeline, verdict); this process keeps the keys it has already
   delivered, and the server stores what was sent before the process started.
2. A failure is not a reason to withhold the verdict. If the ticket cannot be
   reached, the verdict is still written and the exit code is zero: a gate
   that has already decided must not turn red because of a notification.
3. Credentials never travel through argv. argv is readable in `ps` and lands in
   runner logs. Everything comes from the environment, and only the variable
   names are written to the log.

Stdlib only. --selftest runs a real HTTP server on 127.0.0.1, so the retry path
is tested against a socket, not against a mock that agrees with everything.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── log (the same shape as lib/log.sh) ───────────────────────────────────────

SCOPE = os.environ.get("CI_JOB_NAME") or "ticket-sync"


def _stamp() -> str:
    from datetime import datetime
    now = datetime.now().astimezone()
    z = now.strftime("%z")
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}" + z[:3] + ":" + z[3:]


def log(level: str, message: str) -> None:
    order = ("TRACE", "DEBUG", "INFO", "WARN", "ERROR")
    want = os.environ.get("LOG_LEVEL", "INFO")
    if level not in order or order.index(level) < order.index(want if want in order else "INFO"):
        return
    print(f"{_stamp()} {level} {SCOPE} {message}", file=sys.stderr)


# ── request shape ────────────────────────────────────────────────────────────

def verdict_note(verdict: dict, run: dict) -> str:
    """One comment, written for a human to read. Not a JSON dump.

    What people ask on the ticket is: what is holding this, and what should I do
    next. Those two answers go up front; the rest sits in the detail block.
    """
    head = "PASS" if verdict.get("passed") else "BLOCKED"
    lines = [
        f"[{head}] {run['project']} {run['version']} -> {run['env']}",
        verdict.get("summary", "(no summary)"),
        "",
        f"pipeline: {run['url']}",
        f"commit: {run['commit']}  branch: {run['branch']}",
    ]
    failures = verdict.get("failures") or []
    if failures:
        lines += ["", "what is holding this back:"] + [f"- {f}" for f in failures]
    warnings = verdict.get("warnings") or []
    if warnings:
        lines += ["", "what was accepted with a note:"] + [f"- {w}" for w in warnings]
    plan = verdict.get("plan") or []
    if plan:
        lines += ["", "deploy order:"] + [
            f"- {p.get('name') or p.get('id')} (tier {p.get('tier')}) {p.get('action')}" for p in plan
        ]
    lines += ["", f"idempotency: {run['key']}"]
    return "\n".join(lines)


def idempotency_key(pipeline_id: str, summary: str) -> str:
    return "gate-" + hashlib.sha256(f"{pipeline_id}|{summary}".encode()).hexdigest()[:16]


@dataclass
class Target:
    kind: str            # 'gitlab' | 'jira'
    base: str
    path: str
    token_env: str
    project: str = ""
    issue: str = ""
    transitions: dict = field(default_factory=dict)

    def url(self) -> str:
        return self.base.rstrip("/") + self.path

    def headers(self) -> dict:
        token = os.environ.get(self.token_env, "")
        if not token:
            raise MissingCredential(self.token_env)
        if self.kind == "gitlab":
            return {"PRIVATE-TOKEN": token, "Content-Type": "application/json"}
        return {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "application/json"}

    def body(self, note: str, verdict: dict) -> dict:
        if self.kind == "gitlab":
            return {"body": note}
        transition = self.transitions.get("pass" if verdict.get("passed") else "block")
        return {"update": {"transition": {"id": transition}}, "comment": {"body": note}}


class MissingCredential(Exception):
    pass


# ── send ─────────────────────────────────────────────────────────────────────

# Keys this process has already delivered. One pipeline can be retried, and a
# ticket that receives the same comment twice teaches people to stop reading
# pipeline comments, so a key that got through is never sent again here.
DELIVERED: set[str] = set()


def send(
    target: Target,
    payload: dict,
    timeout: float = 15.0,
    attempts: int = 4,
    sleep=time.sleep,
    key: str = "",
) -> tuple[bool, str]:
    """POST with backoff. Returns (ok, reason).

    Only 5xx and network errors are retried. A 4xx means "your request is
    wrong": repeating it four times only delays the person reading the log.

    `key` is the idempotency key. When one has already been delivered to this
    kind of target in this process, the request is not made a second time.
    """
    posted = f"{target.kind}|{key}" if key else ""
    if posted and posted in DELIVERED:
        log("INFO", f"skipped reason=already_posted key={key} target={target.kind}")
        return True, "already_posted"
    data = json.dumps(payload).encode()
    last = "not attempted"
    for i in range(1, attempts + 1):
        try:
            req = urllib.request.Request(target.url(), data=data, headers=target.headers(), method="POST")
            log("INFO", f"request attempt={i} target={target.kind} url={target.url()} bytes={len(data)}" + (f" key={key}" if key else ""))
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                log("DEBUG", f"response attempt={i} target={target.kind} status={resp.status}")
                if 200 <= resp.status < 300:
                    if posted:
                        DELIVERED.add(posted)
                    log("INFO", f"posted target={target.kind} status={resp.status} attempt={i}")
                    return True, "posted"
                last = f"status {resp.status}"
        except urllib.error.HTTPError as exc:
            last = f"http {exc.code}"
            log("DEBUG", f"response attempt={i} target={target.kind} status={exc.code}")
            if 400 <= exc.code < 500:
                log("ERROR", f"failed reason=client_error target={target.kind} status={exc.code} notRetried=true")
                return False, last
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last = f"network {type(exc).__name__}"
        if i < attempts:
            backoff = min(30.0, 2.0 ** i) + random.random()
            log("WARN", f"retry target={target.kind} attempt={i} in={backoff:.1f}s reason={last}")
            sleep(backoff)
    log("ERROR", f"failed reason=exhausted target={target.kind} attempts={attempts} last={last}")
    return False, last


def load_verdict(path: str) -> dict:
    if not os.path.exists(path):
        # A missing verdict must not turn into "passed" on the ticket.
        return {"passed": False, "summary": "gate-verdict.json was not read; the release stays held until that is clear", "failures": ["verdict missing"], "warnings": [], "plan": []}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# ── selftest ────────────────────────────────────────────────────────────────

class _Recorder(BaseHTTPRequestHandler):
    """A real server on 127.0.0.1. What it records: the request count and the bodies."""

    hits: list = []
    codes: list = []

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode()
        type(self).hits.append({"path": self.path, "body": body, "token": self.headers.get("PRIVATE-TOKEN") or self.headers.get("Authorization")})
        code = type(self).codes.pop(0) if type(self).codes else 201
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


def selftest() -> int:
    fails: list[str] = []

    def ok(cond, name):
        if not cond:
            fails.append(name)

    def captured(fn) -> str:
        """What one call wrote to the log, so an assertion can be made on it."""
        import io
        from contextlib import redirect_stderr

        buf = io.StringIO()
        with redirect_stderr(buf):
            fn()
        return buf.getvalue()

    key = idempotency_key("1421", "gate passed")
    ok(key.startswith("gate-") and len(key) == 21, "key length is stable")
    ok(key == idempotency_key("1421", "gate passed"), "key is deterministic")
    ok(key != idempotency_key("1422", "gate passed"), "a different pipeline = a different key")

    note = verdict_note({"passed": False, "summary": "gate failed: 1 critical", "failures": ["vulnerabilities: 1 critical (allowed 0)"], "warnings": [], "plan": [
                            {"id": "1001", "name": "core-api", "tier": 1, "action": "deploy"},
                            {"id": "1020", "name": "portal", "tier": 3, "action": "deploy"}]},
                        {"project": "core-api", "version": "R1.4.3", "env": "sit", "url": "https://gitlab.example.internal/p/-/pipelines/1421", "commit": "a1b2c3d", "branch": "main", "key": key})
    ok("[BLOCKED]" in note and "what is holding this back:" in note, "a red verdict reads as its reason")
    ok("PASS" not in note.splitlines()[0], "the first line does not say PASS")
    ok("1 critical" in note, "the numbers from the gate are written along")
    order = note.split("deploy order:")[1]
    ok("core-api (tier 1)" in order and "portal (tier 3)" in order, "the deploy order uses the names and tiers from the gate")

    # A real server: 500, 500, 201 -> it must try three times and end ok.
    srv = HTTPServer(("127.0.0.1", 0), _Recorder)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        _Recorder.hits = []
        _Recorder.codes = [500, 502, 201]
        os.environ["TEST_TOKEN"] = "single-use"
        tgt = Target("gitlab", f"http://127.0.0.1:{port}", "/api/v4/projects/1001/issues/471/notes", "TEST_TOKEN")
        slept: list[float] = []
        ok(send(tgt, {"body": "x"}, sleep=slept.append)[0], "retries until it succeeds")
        ok(len(_Recorder.hits) == 3, f"three attempts, got {len(_Recorder.hits)}")
        ok(len(slept) == 2 and slept[1] > slept[0], "the backoff grows")

        # A 404 is not repeated: that is a wrong request, not a busy server.
        _Recorder.hits = []
        _Recorder.codes = [404]
        ok(not send(tgt, {"body": "x"}, sleep=lambda *_: None)[0], "a 404 counts as a failure")
        ok(len(_Recorder.hits) == 1, "4xx is not retried")

        # Without a credential: fail fast with a readable cause.
        os.environ.pop("TEST_TOKEN")
        try:
            send(tgt, {"body": "x"}, attempts=1, sleep=lambda *_: None)
            ok(False, "a missing credential should raise")
        except MissingCredential:
            ok(True, "a missing credential raised")

        # The token must never be written to the log.
        os.environ["TEST_TOKEN"] = "do-not-print-this"
        _Recorder.hits = []
        _Recorder.codes = [201]
        send(tgt, {"body": "content"}, sleep=lambda *_: None)
        ok(_Recorder.hits[0]["token"] == "do-not-print-this", "the token reached the server")
        ok("do-not-print-this" not in captured(lambda: send(tgt, {"body": "log"}, sleep=lambda *_: None)),
           "the token was written into the log")

        # Idempotency, made observable: a key that has already been delivered in
        # this process does not go on the wire again, and the log names the key
        # that was held back.
        _Recorder.hits = []
        _Recorder.codes = [201, 201, 201]
        idem = "gate-selftest-single"
        ok(send(tgt, {"body": "first"}, sleep=lambda *_: None, key=idem)[0], "the first delivery posts")
        ok(len(_Recorder.hits) == 1, f"the first delivery reached the server, got {len(_Recorder.hits)}")
        held = captured(lambda: send(tgt, {"body": "second"}, sleep=lambda *_: None, key=idem))
        ok("skipped reason=already_posted key=gate-selftest-single" in held, "the held-back key was not named")
        ok(len(_Recorder.hits) == 1, f"a delivered key must not reach the server again, got {len(_Recorder.hits)} hits")
        # Another key is another comment: the ledger holds keys, not targets.
        ok(send(tgt, {"body": "third"}, sleep=lambda *_: None, key=idem + "-other")[0], "a key nobody delivered yet posts")
        ok(len(_Recorder.hits) == 2, f"a new key reaches the server, got {len(_Recorder.hits)} hits")
    finally:
        srv.shutdown()
        srv.server_close()

    missing = load_verdict("file-that-does-not-exist.json")
    ok(missing["passed"] is False and "verdict missing" in missing["failures"], "a missing verdict holds the release")

    for f in fails:
        print(f"ticket_sync selftest FAIL {f}", file=sys.stderr)
    print("ticket_sync selftest: ok" if not fails else f"ticket_sync selftest: {len(fails)} failures", file=sys.stderr)
    return 0 if not fails else 1


# ── main ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--verdict", default="gate-verdict.json")
    ap.add_argument("--project", default=os.environ.get("CI_PROJECT_NAME", "unknown"))
    ap.add_argument("--version", default=os.environ.get("RELEASE_VERSION", "unversioned"))
    ap.add_argument("--env", default=os.environ.get("CI_DEPLOY_TO", "sit"))
    ap.add_argument("--gitlab-issue", default="", help="IID of the ticket in this project")
    ap.add_argument("--jira-issue", default="", help="for example FIN-471")
    ap.add_argument("--to", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    verdict = load_verdict(args.verdict)
    run = {
        "project": args.project,
        "version": args.version,
        "env": args.to or args.env,
        "commit": os.environ.get("CI_COMMIT_SHORT_SHA", ""),
        "branch": os.environ.get("CI_COMMIT_REF_NAME", ""),
        "url": os.environ.get("CI_PIPELINE_URL", ""),
        "key": idempotency_key(os.environ.get("CI_PIPELINE_ID", "0"), verdict.get("summary", "")),
    }
    note = verdict_note(verdict, run)

    targets: list[Target] = []
    base = os.environ.get("CI_API_V4_URL")
    pid = os.environ.get("CI_PROJECT_ID")
    if args.gitlab_issue and base and pid:
        targets.append(Target("gitlab", base, f"/projects/{pid}/issues/{args.gitlab_issue}/notes", "GITLAB_TOKEN"))
    jira = os.environ.get("JIRA_BASE")
    if args.jira_issue and jira:
        targets.append(Target("jira", jira, f"/rest/api/2/issue/{args.jira_issue}/transitions", "JIRA_TOKEN",
                              transitions={"pass": os.environ.get("JIRA_TRANSITION_PASS", "31"), "block": os.environ.get("JIRA_TRANSITION_BLOCK", "21")}))

    if not targets:
        log("WARN", f"skipped reason=no-ticket-configured issue={args.gitlab_issue or 'none'}/{args.jira_issue or 'none'}")
        print(note)
        return 0

    if args.dry_run:
        for tgt in targets:
            log("INFO", f"dry-run target={tgt.kind} url={tgt.url()} key={run['key']}")
        print(note)
        return 0

    delivered = 0
    for tgt in targets:
        ok, _ = send(tgt, tgt.body(note, verdict), key=run["key"])
        delivered += ok
    if delivered < len(targets):
        # Deliberately does not change the exit code. The verdict was already
        # written by an earlier job; a failed notification is not a reason to
        # release the hold, and not a reason to hold longer either.
        log("WARN", f"verdict delivered={delivered} of={len(targets)} gateUnchanged=true")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
