#!/usr/bin/env python3
"""Blocks a GitHub publish that reuses a stale --body-file.

On 2026-10-28 a review for PR #720 was posted from a body file left over from
two days earlier: the command that should have rewritten it had been denied, so
the contributor got the old review word for word. This hook refuses
`gh pr review|comment|create`, `gh issue comment|create` and
`gh release create|edit` with `--body-file`/`-F <file>` unless the file is
written in the same command or was modified in the last 10 minutes.
"""

import json
import os
import re
import sys
import time

MAX_AGE_SECONDS = 600

PUBLISH = re.compile(
    r"\bgh\s+(?:pr\s+(?:review|comment|create|edit)"
    r"|issue\s+(?:comment|create|edit)"
    r"|release\s+(?:create|edit))\b"
)
BODY_FILE = re.compile(r"(?:--body-file|--notes-file)(?:\s+|=)(\"[^\"]+\"|'[^']+'|\S+)")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    cmd = payload.get("tool_input", {}).get("command", "")
    if not PUBLISH.search(cmd):
        return 0
    for match in BODY_FILE.finditer(cmd):
        raw = match.group(1).strip("'\"")
        if raw == "-":
            continue
        # Written in this same command (heredoc or redirect into it)?
        if re.search(r">\s*" + re.escape(match.group(1)), cmd) or re.search(
            r">\s*\"?" + re.escape(raw) + r"\"?", cmd
        ):
            continue
        # A path built from a variable assigned in this command counts as written
        # here only if the variable is also the target of a redirect.
        var = re.fullmatch(r"\$\{?(\w+)\}?", raw)
        if var and re.search(r">\s*\"?\$\{?" + var.group(1) + r"\}?\"?", cmd):
            continue
        path = os.path.expanduser(os.path.expandvars(raw))
        if not os.path.exists(path):
            print(f"BLOCKED: body file {path} does not exist.", file=sys.stderr)
            return 2
        age = time.time() - os.path.getmtime(path)
        if age > MAX_AGE_SECONDS:
            print(
                f"BLOCKED: {path} was last written {int(age // 60)} min ago. "
                "Write the approved text and post it in the same command; "
                "never reuse an old body file.",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
