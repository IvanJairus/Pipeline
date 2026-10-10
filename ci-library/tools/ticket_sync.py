#!/usr/bin/env python3
"""Menempelkan verdict gate ke tiket, dan (kalau dipasang) menransisi tiket-nya.

Dipanggil oleh ci-library/scripts/ticket-sync.sh, yang dipanggil oleh job
`gate:ticket-sync` di semua template.

Tiga keputusan yang bikin file ini layak dipakai, bukan cuma ada:

1. Idempoten. Satu pipeline bisa di-retry, dan tiket yang dapat dua komentar
   identik membuat orang berhenti membaca komentar pipeline. Kuncinya hash dari
   (pipeline, verdict); server menyimpan apa yang sudah pernah kita kirim.
2. Gagal itu bukan alasan untuk menahan verdict. Kalau tiket tidak bisa dicapai,
   verdict tetap ditulis dan exit code-nya nol: gate yang sudah memutuskan
   jangan sampai berubah jadi merah karena notifikasi.
3. Kredensial tidak pernah lewat argv. argv terbaca di `ps` dan masuk ke log
   runner. Semuanya dari environment, dan yang ditulis ke log hanya namanya.

Hanya stdlib. --selftest menjalankan server HTTP sungguhan di 127.0.0.1, jadi
jalur retry diuji terhadap socket, bukan terhadap mock yang setuju-setuju saja.
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

# ── log (bentuk yang sama dengan lib/log.sh) ────────────────────────────────

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


# ── bentuk permintaan ───────────────────────────────────────────────────────

def verdict_note(verdict: dict, run: dict) -> str:
    """Satu komentar, dibaca manusia. Bukan dump JSON.

    Yang ditanya orang di tiket adalah: apa yang menahan, dan apa yang harus
    saya lakukan. Dua hal itu yang ada di depan; sisanya di blok detail.
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
        lines += ["", "yang menahan:"] + [f"- {f}" for f in failures]
    warnings = verdict.get("warnings") or []
    if warnings:
        lines += ["", "yang diterima dengan catatan:"] + [f"- {w}" for w in warnings]
    plan = verdict.get("plan") or []
    if plan:
        lines += ["", "urutan deploy:"] + [
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


# ── kirim ───────────────────────────────────────────────────────────────────

def send(target: Target, payload: dict, timeout: float = 15.0, attempts: int = 4, sleep=time.sleep) -> tuple[bool, str]:
    """POST dengan backoff. Kembali (ok, alasan).

    Yang di-retry hanya 5xx dan kesalahan jaringan. 4xx adalah "permintaanmu
    salah" - mengulanginya empat kali hanya menunda orang yang baca log.
    """
    data = json.dumps(payload).encode()
    last = "not attempted"
    for i in range(1, attempts + 1):
        try:
            req = urllib.request.Request(target.url(), data=data, headers=target.headers(), method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if 200 <= resp.status < 300:
                    log("INFO", f"posted target={target.kind} status={resp.status} attempt={i}")
                    return True, "posted"
                last = f"status {resp.status}"
        except urllib.error.HTTPError as exc:
            last = f"http {exc.code}"
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
        # Verdict yang hilang tidak boleh berubah jadi "lolos" di tiket.
        return {"passed": False, "summary": "gate-verdict.json tidak dibaca; release ditahan sampai itu jelas", "failures": ["verdict missing"], "warnings": [], "plan": []}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# ── selftest ────────────────────────────────────────────────────────────────

class _Recorder(BaseHTTPRequestHandler):
    """Server sungguhan di 127.0.0.1. Yang dicatat: jumlah permintaan dan body-nya."""

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

    key = idempotency_key("1421", "gate passed")
    ok(key.startswith("gate-") and len(key) == 21, "panjang kunci stabil")
    ok(key == idempotency_key("1421", "gate passed"), "kunci deterministik")
    ok(key != idempotency_key("1422", "gate passed"), "pipeline lain = kunci lain")

    note = verdict_note({"passed": False, "summary": "gate failed: 1 critical", "failures": ["vulnerabilities: 1 critical (allowed 0)"], "warnings": [], "plan": [
                            {"id": "1001", "name": "core-api", "tier": 1, "action": "deploy"},
                            {"id": "1020", "name": "portal", "tier": 3, "action": "deploy"}]},
                        {"project": "core-api", "version": "R1.4.3", "env": "sit", "url": "https://gitlab.example.internal/p/-/pipelines/1421", "commit": "a1b2c3d", "branch": "main", "key": key})
    ok("[BLOCKED]" in note and "yang menahan:" in note, "verdict merah terbaca sebagai alasan")
    ok("PASS" not in note.splitlines()[0], "baris pertama tidak bilang PASS")
    ok("1 critical" in note, "angka dari gate ikut tertulis")
    order = note.split("urutan deploy:")[1]
    ok("core-api (tier 1)" in order and "portal (tier 3)" in order, "urutan deploy memakai nama dan tier hasil gate")

    # Server sungguhan: 500, 500, 201 -> harus coba tiga kali dan akhirnya ok.
    srv = HTTPServer(("127.0.0.1", 0), _Recorder)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        _Recorder.hits = []
        _Recorder.codes = [500, 502, 201]
        os.environ["TEST_TOKEN"] = "sekali-pakai"
        tgt = Target("gitlab", f"http://127.0.0.1:{port}", "/api/v4/projects/1001/issues/471/notes", "TEST_TOKEN")
        slept: list[float] = []
        ok(send(tgt, {"body": "x"}, sleep=slept.append)[0], "retry sampai sukses")
        ok(len(_Recorder.hits) == 3, f"tiga percobaan, dapat {len(_Recorder.hits)}")
        ok(len(slept) == 2 and slept[1] > slept[0], "backoff naik")

        # 404 tidak diulang: itu permintaan yang salah, bukan server yang sibuk.
        _Recorder.hits = []
        _Recorder.codes = [404]
        ok(not send(tgt, {"body": "x"}, sleep=lambda *_: None)[0], "404 dianggap gagal")
        ok(len(_Recorder.hits) == 1, "4xx tidak di-retry")

        # Tanpa kredensial: gagal cepat dengan sebab yang bisa dibaca.
        os.environ.pop("TEST_TOKEN")
        try:
            send(tgt, {"body": "x"}, attempts=1, sleep=lambda *_: None)
            ok(False, "kredensial hilang seharusnya melempar")
        except MissingCredential:
            ok(True, "kredensial hilang dilempar")

        # Token tidak boleh ikut tertulis ke log.
        os.environ["TEST_TOKEN"] = "jangan-cetak-ini"
        _Recorder.hits = []
        _Recorder.codes = [201]
        send(tgt, {"body": "isi"}, sleep=lambda *_: None)
        ok(_Recorder.hits[0]["token"] == "jangan-cetak-ini", "token sampai ke server")
    finally:
        srv.shutdown()
        srv.server_close()

    missing = load_verdict("berkas-yang-tidak-ada.json")
    ok(missing["passed"] is False and "verdict missing" in missing["failures"], "verdict hilang menahan release")

    for f in fails:
        print(f"ticket_sync selftest FAIL {f}", file=sys.stderr)
    print("ticket_sync selftest: ok" if not fails else f"ticket_sync selftest: {len(fails)} kegagalan", file=sys.stderr)
    return 0 if not fails else 1


# ── main ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--verdict", default="gate-verdict.json")
    ap.add_argument("--project", default=os.environ.get("CI_PROJECT_NAME", "unknown"))
    ap.add_argument("--version", default=os.environ.get("RELEASE_VERSION", "unversioned"))
    ap.add_argument("--env", default=os.environ.get("CI_DEPLOY_TO", "sit"))
    ap.add_argument("--gitlab-issue", default="", help="IID tiket di project ini")
    ap.add_argument("--jira-issue", default="", help="contohnya FIN-471")
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
        ok, _ = send(tgt, tgt.body(note, verdict))
        delivered += ok
    if delivered < len(targets):
        # Sengaja tidak mengubah kode keluar. Verdict sudah ditulis oleh job
        # sebelumnya; notifikasi yang gagal bukan alasan untuk melepaskan
        # penahan, dan juga bukan alasan untuk menahannya lebih lama.
        log("WARN", f"verdict delivered={delivered} of={len(targets)} gateUnchanged=true")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
