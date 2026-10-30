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
every fail-open path below are deliberate and tested — see `_TESTS`. The
command is read by publish_command.py, shared with the two release guards:
every publish of a command is checked, and a command that holds `pub publish`
the reader cannot place is blocked, as is any command holding it when that
module cannot load.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import publish_command
except Exception as _e:  # noqa: BLE001 — main() blocks a publish without it
    publish_command = None
    _IMPORT_ERROR = _e


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


def _cwd(payload):
    return payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def _shipping(cmd, payload):
    """The publishes of [cmd] that ship (not --dry-run). Raises PublishUnclear."""
    return [p for p in publish_command.publishes(cmd, _cwd(payload)) if not p.dry_run]


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

def _block(text):
    sys.stderr.write(text + "(guard: .claude/hooks/guard-publish.py)\n")
    return 2


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

    if publish_command is None:
        # Loosely, as anything could be: `pub` (or `packages`) and a publish
        # word anywhere, quotes and backslashes dropped, or `$'…'` beside it.
        text = re.sub(r"[\"'\\]", "", cmd)
        if re.search(r"\b(?:pub|packages)\b", text) and (
            re.search(r"\b(?:publish|lish|lush)\b", text) or "$'" in cmd
        ):
            return _block(
                f"BLOCKED: publish_command.py did not load ({_IMPORT_ERROR!r}), "
                "so this command cannot be read.\n"
            )
        return 0

    try:
        shipping = _shipping(cmd, payload)
    except publish_command.PublishUnclear as e:
        return _block(
            f"BLOCKED: this command holds `pub publish`, but {e}.\n"
            "Write the publish plainly (`cd <package> && dart pub publish`).\n"
        )

    # Every publish of the command, each in the repository it runs in.
    for p in shipping:
        where = p.directory
        if where is None:
            return _block(
                "BLOCKED: cannot tell which directory the publish runs in — a "
                "`cd` or `-C` target is built from a variable, or the command "
                "uses `cd -`, a bare `cd`, `pushd` or `popd`.\n"
                "Write the path literally so the guard checks the right "
                "repository.\n"
            )
        try:
            repo = git(where, "rev-parse", "--show-toplevel")
            problems = _problems(repo)
        except Exception as e:  # noqa: BLE001 — any surprise blocks
            return _block(
                f"BLOCKED: cannot verify the commit is on origin — {e}\n"
                f"Publish directory: {where}\n"
                "A publish is irreversible; an unverifiable state is not a safe "
                "one.\n"
            )
        if problems:
            return _block(
                "BLOCKED: refusing to publish source that is not on the remote.\n"
                f"  repository: {repo}\n"
                + "".join(f"  - {p}\n" for p in problems)
            )
    return 0


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
    ('RELEASE_SKIP_REGISTRY="no device" dart pub publish -f', True),  # was a bypass
    ("RELEASE_SKIP_DOCS='two words' dart pub publish", True),  # was a bypass
    ("RELEASE_SKIP_REGISTRY= dart pub publish", True),  # was a bypass
    ('env RELEASE_SKIP_REGISTRY="a b" X=1 dart pub publish', True),  # was a bypass
    ("FOO=$(pwd) dart pub publish", True),
    ("FOO=$(a $(b) c) dart pub publish", True),  # was a bypass
    ("FOO=$(printf ')') dart pub publish", True),  # was a bypass
    ("FOO=`pwd` dart pub publish", True),
    ("fvm dart pub publish", True),  # was a bypass
    ("sudo dart pub publish", True),  # was a bypass
    ('bash -c "dart pub publish"', True),  # was a bypass
    ("xargs dart pub publish", True),  # unclear: blocked
    ("dart pub publish --dry-run", False),
    ("cd x && dart pub publish --dry-run", False),
    ('echo \'{"command":"dart pub publish"}\' | cat', False),
    ('grep -r "dart pub publish" docs/', False),
    ("cat <<'EOF'\ndart pub publish\nEOF", False),  # was blocked
    ("git push origin main", False),
]

# (payload, command, expected directory of the first publish) — which
# repository gets inspected. `None` means the guard must refuse, not guess.
_DIR_TESTS = [
    # The bug this fixes: no `cd`, so the tool's own cwd decides — NOT the
    # session project, which may be an entirely different checkout.
    ({"cwd": "/w/pkg"}, "dart pub publish --force", "/w/pkg"),
    ({"cwd": "/w/a"}, "cd /w/b && dart pub publish", "/w/b"),
    ({"cwd": "/w/a"}, "cd packages/x && dart pub publish", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "cd packages\ncd x\ndart pub publish", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "dart pub publish\ncd /elsewhere", "/w/a"),
    ({"cwd": "/w/a"}, 'cd "$PKG" && dart pub publish', None),
    ({"cwd": "/w/a"}, "cd $PKG && dart pub publish", None),
    ({"cwd": "/w/a"}, "dart pub publish -C /w/b --force", "/w/b"),
    ({"cwd": "/w/a"}, "cd packages && dart pub publish -C x", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "dart pub publish -Cpackages/x", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "dart pub publish --directory=packages/x", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, "flutter pub publish --directory packages/x", "/w/a/packages/x"),
    ({"cwd": "/w/a"}, 'dart pub publish -C "$PKG"', None),
    ({"cwd": "/w/a"}, "cd /w/b && cd - && dart pub publish", None),
    ({"cwd": "/w/a"}, "cd -P /w/b && dart pub publish", None),
    ({"cwd": "/w/a"}, "cd\ndart pub publish", None),
    ({"cwd": "/w/a"}, "pushd /w/b && dart pub publish", None),
    ({"cwd": "/w/a"}, "dart pub publish\ncd -", "/w/a"),
    ({"cwd": "/w/a"}, "(cd /w/b) && dart pub publish", "/w/a"),
]


def _run_main(cmd, cwd):
    import contextlib
    import io

    stdin = sys.stdin
    sys.stdin = io.StringIO(json.dumps({"tool_input": {"command": cmd}, "cwd": cwd}))
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return main()
    finally:
        sys.stdin = stdin


_HOOK = "guard-publish"


def _may_publish(raw):
    """Whether the hook payload [raw] may hold a publish, read loosely; an
    unreadable payload may."""
    try:
        cmd = (json.loads(raw).get("tool_input") or {}).get("command") or ""
        if not isinstance(cmd, str):
            return True
        if publish_command is not None:
            return publish_command.mentions_publish(cmd)
        text = re.sub(r"[\"'\\]", "", cmd)
        return bool(
            re.search(r"\b(?:pub|packages)\b", text)
            and (re.search(r"\b(?:publish|lish|lush)\b", text) or "$'" in cmd)
        )
    except BaseException:  # noqa: BLE001 — unsure: may publish
        return True


def _guarded_main():
    """main(), failing closed for a publish only: a crash on a command that
    may publish is exit 2 (block), never the exit 1 of a traceback, which a
    PreToolUse hook reads as non-blocking; on any other command it allows."""
    import io

    try:
        raw = sys.stdin.read()
    except BaseException as e:  # noqa: BLE001 — a payload not read may publish
        sys.stderr.write(f"BLOCKED: {_HOOK} could not read the hook payload ({e!r}).\n")
        return 2
    sys.stdin = io.StringIO(raw)
    try:
        return main()
    except BaseException as e:  # noqa: BLE001 — a surprise blocks a publish
        if not _may_publish(raw):
            sys.stderr.write(f"{_HOOK} failed ({e!r}) on a command with no publish; allowed.\n")
            return 0
        sys.stderr.write(
            f"BLOCKED: {_HOOK} failed ({e!r}); a publish in an unknown state is "
            "not a safe one.\n"
        )
        return 2


def _crash_blocks_publish_only():
    """Self-test: with main() crashing, a publish blocks and `git status` does
    not. Returns the failures."""
    import contextlib
    import io

    bad = []
    real = globals()["main"]
    globals()["main"] = lambda: 1 / 0
    try:
        for cmd, want in (("dart pub publish -f", 2), ("dart pub\\\npublish", 2), ("git status", 0)):
            stdin = sys.stdin
            sys.stdin = io.StringIO(json.dumps({"tool_input": {"command": cmd}}))
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    got = _guarded_main()
            finally:
                sys.stdin = stdin
            if got != want:
                bad.append(f"a crash on {cmd!r}: exit {got}, want {want}")
    finally:
        globals()["main"] = real
    return bad


def _self_test():
    import tempfile

    bad = list(publish_command.self_test())
    bad += _crash_blocks_publish_only()
    for cmd, want in _TESTS:
        try:
            got = bool(_shipping(cmd, {"cwd": "/w"}))
        except publish_command.PublishUnclear:
            got = True
        if got != want:
            bad.append(f"want_block={want} got={got}  {cmd!r}")
    for payload, cmd, want in _DIR_TESTS:
        got = _shipping(cmd, payload)[0].directory
        if got != want:
            bad.append(f"want_dir={want!r} got={got!r}  {cmd!r}")
    # Two publishes in two repositories: the second one's is checked too.
    with tempfile.TemporaryDirectory() as root:
        clean = os.path.join(root, "clean")
        dirty = os.path.join(root, "dirty")
        origin = os.path.join(root, "origin.git")
        git(root, "init", "-q", "--bare", origin)
        for repo in (clean, dirty):
            os.makedirs(repo)
            git(repo, "init", "-q", "-b", "main")
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t",
                "commit", "-q", "--allow-empty", "-m", "t")
            git(repo, "remote", "add", "origin", origin)
        git(clean, "push", "-q", "origin", "main")
        open(os.path.join(dirty, "x"), "w").close()
        if _run_main(f"dart pub publish -C {clean}", root) != 0:
            bad.append("a pushed, clean repository is blocked")
        code = _run_main(
            f"dart pub publish -C {clean} && dart pub publish -C {dirty}", root
        )
        if code != 2:
            bad.append(f"the second publish's dirty repository passed: exit {code}")
    for line in bad:
        print(f"  FAIL {line}")
    total = len(_TESTS) + len(_DIR_TESTS) + 2 + len(publish_command._CASES)
    print(f"  {total - len(bad)}/{total} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(_guarded_main())
