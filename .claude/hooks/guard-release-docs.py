#!/usr/bin/env python3
"""Block `dart pub publish` of a package whose code changed but whose docs did not.

Why this exists: twice in one session a package was released with the code shipped
but the docs skipped — agent 0.2.3 published without its pub.dev README updated
(had to ship 0.2.4 the same day), and the 1.5.9 vision-backend docs were split off
into a separate website PR instead of riding the release PR. The `release` skill
says docs (Step 12: version pins + new-API docs) are MANDATORY ON EVERY RELEASE and
"commit the website/ changes on your release branch / PR" (one PR, not two). The
skill was read and the docs were still deferred — which is the argument for a hook
over more prose: a checklist advises, a hook refuses. (Same lesson as
guard-publish.py.)

Blocks a real publish (not --dry-run) of package X when, in the commit range that
introduced X's current `version:` (that commit .. HEAD), X's `lib/` changed but
its own pub.dev-facing `README.md` did NOT. The README specifically — a
`website/content/docs/` edit is deliberately NOT accepted as a substitute:
website docs aren't package-scoped, so a sibling package's website change (batch
release) or a website-only-but-README-skipped change (the agent 0.2.3 miss this
hook was built for) would otherwise pass. website/README both belong in the
release, but only README is enforceable per-package here; the Step-12b website
docs are enforced by review + the DoD checklist.

The package is located from the directory the publish RUNS IN, and every git
question is asked of THAT repository. Both used to come from $CLAUDE_PROJECT_DIR
plus a hardcoded `packages/<name>` layout, which meant this hook could not see a
single-package repo at all (it refused, having no idea what was being published)
and, working from a second checkout, would have asked its questions of the wrong
repository. A package that is its own repo is the ordinary case outside this
monorepo, so `packages/<name>` is now one shape rather than the only one.

This range/boundary logic is only exact when HEAD == the release commit — which is
always true when this PreToolUse hook actually fires (at publish time).
It is NOT a general retroactive audit.

Override for a genuine code-only release with no README surface (rare) by putting
`RELEASE_SKIP_DOCS="<reason>"` in front of that publish. It covers that
one publish only; on another command of the chain, exported earlier, or with
an empty reason it is not an override. Every publish of a command is checked.

Fail-closed: if git can't be consulted, or the package/version can't be resolved,
BLOCK — an irreversible publish in an unknown state is not a safe one.

Exit 0 allows, exit 2 blocks with the reason on stderr.
Run `python3 guard-release-docs.py --self-test` to check the matching rules.
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


def _checked(cmd, payload, var):
    """The publishes of [cmd] that ship and carry no reasoned [var] skip.

    Raises PublishUnclear for a command whose publishes cannot be read.
    """
    return [
        p
        for p in publish_command.publishes(cmd, _cwd(payload))
        if not p.dry_run and p.skip_reason(var) is None
    ]


def _unreadable(cmd, hook):
    """The block for a command this hook cannot read; None when it can."""
    if publish_command is None:
        # Loosely, as anything could be: `pub` (or `packages`) and a publish
        # word anywhere, quotes and backslashes dropped, or `$'…'` beside it.
        text = re.sub(r"[\"'\\]", "", cmd)
        if re.search(r"\b(?:pub|packages)\b", text) and (
            re.search(r"\b(?:publish|lish|lush)\b", text) or "$'" in cmd
        ):
            return (
                f"BLOCKED: publish_command.py did not load ({_IMPORT_ERROR!r}), "
                f"so this command cannot be read.\n(guard: .claude/hooks/{hook})\n"
            )
    return None


def _located(p):
    """(repo_root, package_prefix, label) for the package [p] publishes.

    `package_prefix` is repo-relative and ends in '/' — or is '' when the
    package IS the repository root, which is what every single-package repo
    looks like.
    """
    where = p.directory
    if where is None:
        raise GitUnavailable(
            "a `cd` or `-C` target is built from a variable, or the command uses "
            "`cd -`, a bare `cd`, `pushd` or `popd`, so the publish directory is "
            "unknown — write the path literally"
        )
    if not os.path.isfile(os.path.join(where, "pubspec.yaml")):
        raise GitUnavailable(f"no pubspec.yaml in {where} — nothing to check")

    root = git(where, "rev-parse", "--show-toplevel")
    rel = os.path.relpath(os.path.realpath(where), os.path.realpath(root))
    prefix = "" if rel == "." else rel.replace(os.sep, "/") + "/"
    return root, prefix, (prefix.rstrip("/") or os.path.basename(root))


def _current_version(root, prefix):
    path = os.path.join(root, prefix, "pubspec.yaml")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"version:\s*(\S+)", line)
            if m:
                return m.group(1)
    raise GitUnavailable(f"no version: in {prefix}pubspec.yaml")


def _doc_problem(root, prefix, label):
    """Return a block-reason string, or None if the release's docs are fine."""
    version = _current_version(root, prefix)
    # The commit that set the CURRENT version is the release boundary. -S finds
    # where the exact `version: V` string entered pubspec.yaml.
    boundary = git(
        root, "log", "-1", "--format=%H", "-S", f"version: {version}",
        "--", f"{prefix}pubspec.yaml",
    )
    if not boundary:
        # A version set while resolving a merge (a stacked release branch that
        # took main's published numbers and moved to the next patch) lives only
        # in the merge commit, which `git log -S` skips without -m. Fall back to
        # the merge that brought the version into this branch's first-parent
        # line: the release boundary is then the merge, and boundary~1 is the
        # branch as it was before it.
        boundary = git(
            root, "log", "-1", "--format=%H", "-m", "--first-parent",
            "-S", f"version: {version}", "--", f"{prefix}pubspec.yaml",
        )
    if not boundary:
        raise GitUnavailable(
            f"cannot locate the commit that set version {version} for {label}"
        )
    # Files changed in boundary..HEAD, plus the boundary commit itself.
    changed = set(
        git(root, "diff", "--name-only", f"{boundary}~1", "HEAD").splitlines()
    )
    lib_prefix = f"{prefix}lib/"
    code_changed = any(f.startswith(lib_prefix) for f in changed)
    if not code_changed:
        return None  # docs-only / no public code change → nothing to enforce

    # Require the package's OWN README (the pub.dev landing page). A global
    # website/content/docs/ edit is NOT a substitute: the motivating miss (agent
    # 0.2.3) updated website/agent.md but skipped the README and had to re-ship as
    # 0.2.4. Accepting any website edit would also let a co-released package in a
    # batch (e.g. "core + speech") mask another package whose README was skipped.
    # README is package-scoped, so it can't be borrowed from a sibling.
    readme = f"{prefix}README.md"
    if readme in changed:
        return None

    return (
        f"{lib_prefix} changed since v{version} was set ({boundary[:10]}) "
        f"but {readme} was not updated.\n"
        "  The release skill (Step 12) requires the pub.dev-facing README to ship\n"
        "  the new/changed API in the SAME release (website/content/docs is not a\n"
        "  substitute — it's not package-scoped). If this release genuinely has no\n"
        '  README surface, re-run with RELEASE_SKIP_DOCS="<reason>" in front of the publish.'
    )


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except Exception as e:
        sys.stderr.write(
            f"BLOCKED: guard-release-docs could not read the hook payload ({e!r}).\n"
        )
        return 2

    unreadable = _unreadable(cmd, "guard-release-docs.py")
    if unreadable:
        sys.stderr.write(unreadable)
        return 2
    if publish_command is None:
        return 0
    # Every publish of the command, each with its own RELEASE_SKIP_DOCS: one
    # on another command of the chain, or an empty one, is no skip.
    try:
        checked = _checked(cmd, payload, "RELEASE_SKIP_DOCS")
    except publish_command.PublishUnclear as e:
        sys.stderr.write(
            f"BLOCKED: this command holds `pub publish`, but {e}.\n"
            "Write the publish plainly (`cd <package> && dart pub publish`).\n"
            "(guard: .claude/hooks/guard-release-docs.py)\n"
        )
        return 2
    for p in checked:
        try:
            root, prefix, label = _located(p)
            problem = _doc_problem(root, prefix, label)
        except Exception as e:  # noqa: BLE001 — any surprise blocks
            sys.stderr.write(
                f"BLOCKED: cannot verify docs shipped with this release — {e}\n"
                "A publish is irreversible; an unverifiable state is not a safe one.\n"
            )
            return 2
        if problem is not None:
            sys.stderr.write(
                "BLOCKED: release is missing its docs.\n"
                f"  repository: {root}\n  - "
                + problem
                + "\n(guard: .claude/hooks/guard-release-docs.py)\n"
            )
            return 2
    return 0


# (command, publishes to check) — matching-rule cases only; the git-based doc
# check is exercised on the live repo and by _end_to_end. None: the command
# cannot be read and is blocked.
_TESTS = [
    ("dart pub publish --force", 1),
    ("cd packages/flutter_edge_ai_agent && dart pub publish", 1),
    ("cd packages/x\ndart pub publish", 1),  # multiline was a guard-publish bypass
    ("timeout 900 dart pub publish", 1),  # wrapper was a bypass
    ("dart pub publish --dry-run", 0),
    ("dart pub publish --dry-run && dart pub publish", 1),
    ('RELEASE_SKIP_DOCS="x" dart pub publish', 0),
    ('RELEASE_SKIP_DOCS="two words" dart pub publish', 0),
    ('RELEASE_SKIP_REGISTRY="no device" dart pub publish', 1),
    ("RELEASE_SKIP_DOCS= dart pub publish", 1),  # was a skip
    ('RELEASE_SKIP_DOCS="  " dart pub publish', 1),
    ("RELEASE_SKIP_DOCS=x echo hi && dart pub publish", 1),  # was a skip
    ("echo RELEASE_SKIP_DOCS=note && dart pub publish", 1),
    ("cd a && dart pub publish -f && cd ../b && dart pub publish -f", 2),  # was 1
    ('RELEASE_SKIP_DOCS="r" dart pub publish -C a; dart pub publish -C b', 1),
    ("FOO=$(pwd) dart pub publish", 1),
    ("FOO=$(a $(b) c) dart pub publish", 1),
    ("fvm dart pub publish", 1),
    ('bash -c "dart pub publish"', 1),
    ("xargs dart pub publish", None),
    ("git push origin main", 0),
    ('grep -r "dart pub publish" docs/', 0),
    ("cat <<'EOF'\ndart pub publish\nEOF", 0),
]

# (payload, command, expected publish directory). The monorepo shapes the old
# `packages/<name>` parser handled, plus the single-package repo it could not
# see at all.
_DIR_TESTS = [
    ({"cwd": "/r"}, "cd packages/flutter_edge_ai_agent && dart pub publish",
     "/r/packages/flutter_edge_ai_agent"),
    ({"cwd": "/r/packages/flutter_edge_ai"}, "dart pub publish",
     "/r/packages/flutter_edge_ai"),
    ({"cwd": "/r"}, "cd packages/a && cd /r/packages/b && dart pub publish",
     "/r/packages/b"),  # last cd wins
    ({"cwd": "/elsewhere/large_file_handler"}, "dart pub publish --force",
     "/elsewhere/large_file_handler"),  # a package that IS the repo
    ({"cwd": "/r"}, 'cd "$PKG" && dart pub publish', None),
    # pub's own directory flag; destinations not in the text block.
    ({"cwd": "/r"}, "dart pub publish -C packages/flutter_edge_ai --force",
     "/r/packages/flutter_edge_ai"),
    ({"cwd": "/r"}, "dart pub publish --directory=packages/x", "/r/packages/x"),
    ({"cwd": "/r"}, 'dart pub publish -C "$PKG"', None),
    ({"cwd": "/r"}, "cd packages/a && cd - && dart pub publish", None),
    ({"cwd": "/r"}, "cd\ndart pub publish", None),
    ({"cwd": "/r"}, "pushd packages/a && dart pub publish", None),
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


def _end_to_end():
    """main() on a scratch package; the failures."""
    import tempfile

    global _doc_problem
    bad = []
    with tempfile.TemporaryDirectory() as repo:
        with open(os.path.join(repo, "pubspec.yaml"), "w") as fh:
            fh.write("name: pkg\nversion: 1.0.0\n")
        git(repo, "init", "-q")
        real = _doc_problem
        try:
            # A check that raises something other than GitUnavailable/OSError
            # blocks; it used to escape main() as exit 1, which allows.
            def boom(*_):
                raise ValueError("boom")

            _doc_problem = boom
            if _run_main("dart pub publish -f", repo) != 2:
                bad.append("an unexpected exception does not block")
            # Every publish is checked: the second one's problem blocks.
            calls = []

            def second_fails(root, prefix, label):
                calls.append(root)
                return None if len(calls) == 1 else "missing"

            _doc_problem = second_fails
            if _run_main("dart pub publish -f && dart pub publish -f", repo) != 2:
                bad.append("the second publish's problem passed")
            _doc_problem = lambda *_: "missing"
            if _run_main('RELEASE_SKIP_DOCS="r" dart pub publish -f', repo) != 0:
                bad.append("a reasoned skip still blocks")
            if _run_main("RELEASE_SKIP_DOCS= dart pub publish -f", repo) != 2:
                bad.append("an empty skip passes")
        finally:
            _doc_problem = real
    return bad


_HOOK = "guard-release-docs"


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
    bad = list(publish_command.self_test())
    bad += _crash_blocks_publish_only()
    for cmd, want in _TESTS:
        try:
            got = len(_checked(cmd, {"cwd": "/r"}, "RELEASE_SKIP_DOCS"))
        except publish_command.PublishUnclear:
            got = None
        if got != want:
            bad.append(f"{cmd!r}: checked={got}, want {want}")
    for payload, cmd, want in _DIR_TESTS:
        got = _checked(cmd, payload, "RELEASE_SKIP_DOCS")[0].directory
        if got != want:
            bad.append(f"want_dir={want!r} got={got!r}  {cmd!r}")
    bad += _end_to_end()
    for line in bad:
        print(f"  FAIL {line}")
    total = len(_TESTS) + len(_DIR_TESTS) + 5 + len(publish_command._CASES)
    print(f"  {total - len(bad)}/{total} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(_guarded_main())
