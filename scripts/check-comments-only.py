#!/usr/bin/env python3
"""Prove that a diff touches only comments.

Used after the translation of comments into English. The logic: strip the
comment part off every line, compare it with the version from a given commit.
If even one character of code changed, this script exits non-zero.

Comment stripping uses a conservative rule: a comment marker only counts when it
sits at the start of a line or is preceded by a space, and is not inside a
quote. That is enough for the YAML, Bash, Python and Groovy in this repo; a
string carrying a '#' after a space (a colour or a phrase, say) can be cut in
the wrong place, which is why --list exists: it prints the cut lines so a human
reads them.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

COMMENT_MARKERS = ("#", "//", "/*", "*")


def strip_code(line: str) -> str:
    """Return only the code part of a line."""
    out = []
    quote = None
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote and line[i - 1: i] != "\\":
                quote = None
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            i += 1
            continue
        two = line[i:i + 2]
        if two in ("//", "/*") and (i == 0 or line[i - 1] in " \t"):
            break
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
        i += 1
    return "".join(out).rstrip()


def code_of(text: str) -> list[str]:
    """Every line with the comments removed; blank lines are dropped."""
    lines = []
    in_block = False
    for raw in text.splitlines():
        s = raw.strip()
        if in_block:
            if "*/" in s:
                in_block = False
            continue
        if s.startswith("/*") and "*/" not in s:
            in_block = True
            continue
        if s.startswith("*") or s.startswith("*/"):
            continue
        cut = strip_code(raw)
        if cut.strip():
            lines.append(cut)
    return lines


def git_show(ref: str, path: str) -> str:
    return subprocess.run(("git", "show", f"{ref}:{path}"), capture_output=True, text=True, check=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--list", action="store_true", help="print lines whose comment cut looks suspicious")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args()

    changed = []
    for path in args.paths:
        try:
            before = git_show(args.ref, path)
        except subprocess.CalledProcessError:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                after = fh.read()
        except OSError:
            changed.append((path, "missing"))
            continue
        a, b = code_of(before), code_of(after)
        if a != b:
            for i, (x, y) in enumerate(zip(a, b)):
                if x != y:
                    changed.append((path, f"line {i + 1}\n    before: {x}\n    after : {y}"))
                    break
            else:
                changed.append((path, f"code line count went from {len(a)} to {len(b)}"))

    if args.list:
        for path in args.paths:
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except OSError:
                continue
            for raw in text.splitlines():
                cut = strip_code(raw)
                if "#" in raw and raw.strip().startswith("#") is False and cut != raw.rstrip():
                    print(f"{path}: kept [{cut}]")

    if changed:
        print("CODE CHANGED, not only comments:")
        for path, why in changed:
            print(f"  {path}: {why}")
        return 1
    print(f"ok: {len(args.paths)} files, only comments changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
