#!/usr/bin/env python3
"""Block `dart pub publish` unless the exact commit being published is reachable.

Why this exists: on 2026-08-15 flutter_gemma_litertlm 1.4.0 was published while
the local branch was 20+ commits ahead of origin. For ~25 minutes the package
existed on pub.dev with no corresponding source anywhere on GitHub — nobody
could have reproduced or reviewed what shipped.

The release skill already states the correct order (step 9 push, step 10
publish). It was read and the order was still inverted, which is the argument
for a guard rather than more prose: a checklist advises, a hook refuses.

The first version of this guard was itself reviewed and found to be a no-op on
the most likely command shape (a two-line `cd` + publish), so the matching and
every fail-open path below are deliberate and tested — see `_TESTS`.

The repository inspected is the one the publish RUNS IN, not $CLAUDE_PROJECT_DIR.
Reading the session's project was wrong in both directions, and the harmless
direction is the one that got noticed: on 2026-08-30 it blocked a clean, pushed
package in a second checkout because the SESSION repo had unrelated edits. The
dangerous direction is the same bug with the operands swapped — a dirty package
in that second checkout would have sailed through whenever the session repo
happened to be clean, which is precisely the state this guard exists to refuse.
So the block message now names the repository it looked at; had it done so, the
mis-scope would have been obvious rather than baffling.

Blocks a real publish (not --dry-run) when:
  * the working tree is dirty      -> the archive matches no commit
  * HEAD is not on origin          -> the published source is unreachable
  * the publish directory is unknown or outside a git repo -> nothing to check
  * git itself cannot be consulted -> we do not know, and not knowing is a block

Exit 0 allows, exit 2 blocks with the reason on stderr.
Run `python3 guard-publish.py --self-test` to check the matching rules.
"""
import json
import os
import re
import subprocess
import sys

# Must sit in *command position*: at the start of a line, or right after a
# separator, optionally behind an env assignment or a wrapper like `timeout`.
# re.MULTILINE is load-bearing — without it `^` anchors to the start of the
# whole string, and a newline is not a separator, so every multi-line shell
# block walked straight past this guard.
PUBLISH_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*"
    r"(?:\w+=\S+\s+)*"  # FOO=bar dart pub publish
    r"(?:(?:timeout|nice|env|command|stdbuf)\s+\S+\s+)*"  # timeout 900 dart ...
    r"(?:dart|flutter)\s+pub\s+publish\b",
    re.MULTILINE,
)

# --dry-run must belong to the same command, not merely appear somewhere on the
# line. `dart pub publish --dry-run && dart pub publish` is the canonical
# verify-then-ship one-liner and must NOT be exempt.
DRY_RUN_RE = re.compile(r"(?<![\w-])--dry-run(?![\w-])")

# `cd` in command position. The Bash tool's own cwd persists between calls, but
# a release is nearly always written as `cd <package>` followed by the publish,
# so the directory that matters is wherever those leave us.
CD_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*cd\s+(?!-)" r"(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)",
    re.MULTILINE,
)


class GitUnavailable(RuntimeError):
    """git could not be consulted — treated as a block, never as 'clean'."""


def git(repo, *args):
    """Run git in [repo], or raise. '' on failure would read as 'no problems'."""
    try:
        r = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GitUnavailable(f"git {' '.join(args)}: {e}") from e
    if r.returncode != 0:
        raise GitUnavailable(
            f"git {' '.join(args)} exited {r.returncode}: {r.stderr.strip()}"
        )
    return r.stdout.strip()


def _publish_is_exempt(cmd):
    """True only if every publish invocation on the line carries --dry-run."""
    for m in PUBLISH_RE.finditer(cmd):
        # the rest of this one command, up to the next separator
        tail = re.split(r"[;&|\n]", cmd[m.end() :], maxsplit=1)[0]
        if not DRY_RUN_RE.search(tail):
            return False
    return True


def publish_dir(cmd, payload):
    """Where the publish will run, or None when that cannot be determined.

    Only `cd`s BEFORE the publish count; one after it changes nothing about the
    archive. An unresolvable target (a variable) yields None rather than a
    guess: checking the wrong repository is how this guard failed before, and a
    wrong answer here is worse than no answer.
    """
    base = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    first = PUBLISH_RE.search(cmd)
    limit = first.start() if first else len(cmd)

    for m in CD_RE.finditer(cmd):
        if m.start() >= limit:
            break
        target = m.group(1)
        if len(target) > 1 and target[0] in "\"'" and target[-1] == target[0]:
            target = target[1:-1]
        if "$" in target or "`" in target:
            return None
        target = os.path.expanduser(target)
        base = target if os.path.isabs(target) else os.path.join(base, target)

    return os.path.normpath(base)


def _problems(repo):
    """Return a list of reasons to block. Raises GitUnavailable if git fails."""
    out = []

    if git(repo, "status", "--porcelain"):
        out.append(
            "the working tree is dirty — the published archive would not "
            "correspond to any commit"
        )

    head = git(repo, "rev-parse", "HEAD")
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")

    if branch == "HEAD":
        out.append("detached HEAD — publish from a branch that exists on origin")
        return out

    # --exit-code + a full refname: `ls-remote --heads origin main` also matches
    # refs/heads/backup/main and can put the wrong SHA first.
    try:
        line = git(repo, "ls-remote", "--exit-code", "origin", f"refs/heads/{branch}")
    except GitUnavailable:
        out.append(f"branch '{branch}' does not exist on origin — push it first")
        return out

    remote = line.split("\t")[0].split()[0]
    if remote == head:
        return out

    # Distinguish ahead / behind / diverged: telling someone to push when they
    # need to pull is how a guard gets switched off.
    ahead = git(repo, "rev-list", "--count", f"{remote}..{head}")
    behind = git(repo, "rev-list", "--count", f"{head}..{remote}")
    if ahead != "0" and behind == "0":
        out.append(f"{ahead} unpushed commit(s) — `git push origin {branch}`")
    elif ahead == "0":
        out.append(
            f"HEAD is {behind} commit(s) behind origin/{branch} — `git pull` "
            "and publish the merged tree"
        )
    else:
        out.append(
            f"diverged from origin/{branch} ({ahead} ahead, {behind} behind) — "
            "reconcile before publishing"
        )
    return out


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except Exception as e:
        sys.stderr.write(
            f"BLOCKED: guard-publish could not read the hook payload ({e!r}).\n"
            "Refusing to allow an irreversible publish it could not inspect.\n"
        )
        return 2

    if not PUBLISH_RE.search(cmd):
        return 0
    if _publish_is_exempt(cmd):
        return 0

    where = publish_dir(cmd, payload)
    if where is None:
        sys.stderr.write(
            "BLOCKED: cannot tell which directory the publish runs in — the "
            "`cd` target is built from a variable.\n"
            "Write the path literally so the guard checks the right repository.\n"
        )
        return 2

    try:
        repo = git(where, "rev-parse", "--show-toplevel")
        problems = _problems(repo)
    except GitUnavailable as e:
        sys.stderr.write(
            f"BLOCKED: cannot verify the commit is on origin — {e}\n"
            f"Publish directory: {where}\n"
            "A publish is irreversible; an unverifiable state is not a safe one.\n"
        )
        return 2

    if not problems:
        return 0

    sys.stderr.write(
        "BLOCKED: refusing to publish source that is not on the remote.\n"
        f"  repository: {repo}\n"
        + "".join(f"  - {p}\n" for p in problems)
        + "(guard: .claude/hooks/guard-publish.py)\n"
    )
    return 2


# (command, should_block) — the cases that made earlier versions useless.
_TESTS = [
    ("dart pub publish --force", True),
    ("cd packages/x && dart pub publish", True),
    ("cd packages/x\ndart pub publish", True),  # was a bypass
    ("set -e\ncd packages/x\n  dart pub publish -f", True),  # was a bypass
    ("timeout 900 dart pub publish", True),  # was a bypass
    ("PUB_HOSTED_URL=x dart pub publish", True),  # was a bypass
    ("cd x; (dart pub publish)", True),  # was a bypass
    ("dart pub publish --dry-run && dart pub publish", True),  # was a bypass
    ("flutter pub publish", True),
    ("dart pub publish --dry-run", False),
    ("cd x && dart pub publish --dry-run", False),
    ('echo \'{"command":"dart pub publish"}\' | cat', False),
    ('grep -r "dart pub publish" docs/', False),
    ("git push origin main", False),
]

# (payload, command, expected directory) — which repository gets inspected.
# `None` means the guard must refuse rather than guess.
_DIR_TESTS = [
    # The bug this fixes: no `cd`, so the tool's own cwd decides — NOT the
    # session project, which may be an entirely different checkout.
    ({"cwd": "/w/pkg"}, "dart pub publish --force", "/w/pkg"),
    ({"cwd": "/w/a"}, "cd /w/b && dart pub publish", "/w/b"),
    ({"cwd": "/w/a"}, "cd packages/x && dart pub publish", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "cd packages\ncd x\ndart pub publish", "/w/a/packages/x"),
    # A `cd` after the publish changes nothing about what was published.
    ({"cwd": "/w/a"}, "dart pub publish\ncd /elsewhere", "/w/a"),
    # Unresolvable target: refuse instead of inspecting a guessed directory.
    ({"cwd": "/w/a"}, 'cd "$PKG" && dart pub publish', None),
    ({"cwd": "/w/a"}, "cd $PKG && dart pub publish", None),
]


def _self_test():
    bad = 0
    for cmd, want in _TESTS:
        got = bool(PUBLISH_RE.search(cmd)) and not _publish_is_exempt(cmd)
        if got != want:
            bad += 1
            print(f"  FAIL want_block={want} got={got}  {cmd!r}")

    for payload, cmd, want in _DIR_TESTS:
        got = publish_dir(cmd, payload)
        if got != want:
            bad += 1
            print(f"  FAIL want_dir={want!r} got={got!r}  {cmd!r}")

    total = len(_TESTS) + len(_DIR_TESTS)
    print(f"  {total - bad}/{total} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
