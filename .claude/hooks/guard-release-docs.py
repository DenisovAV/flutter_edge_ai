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
`RELEASE_SKIP_DOCS=<reason>` in the command.

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

# Mirror guard-publish.py's command-position matcher (MULTILINE is load-bearing:
# a `cd` line followed by the publish on the next line must still match).
PUBLISH_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*"
    r"(?:\w+=\S+\s+)*"
    r"(?:(?:timeout|nice|env|command|stdbuf)\s+\S+\s+)*"
    r"(?:dart|flutter)\s+pub\s+publish\b",
    re.MULTILINE,
)
DRY_RUN_RE = re.compile(r"(?<![\w-])--dry-run(?![\w-])")
# RELEASE_SKIP_DOCS must sit in command position (an env assignment prefix),
# not merely appear in an echo/grep of the string.
SKIP_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*(?:\w+=\S+\s+)*RELEASE_SKIP_DOCS=", re.MULTILINE
)
# Duplicated from guard-publish.py on purpose: hooks are standalone files with
# no shared import path, and a hook that fails to load is a hook that does not
# run. Keep the two in step.
CD_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*cd[ \t]+(?!-)" r"(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)",
    re.MULTILINE,
)
OPAQUE_CD_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*(?:cd[ \t]+-|cd[ \t]*(?=[;&|)\n]|$)|pushd\b|popd\b)",
    re.MULTILINE,
)
PUB_DIR_RE = re.compile(
    r"(?<![\w-])(?:-C[ \t]*|--directory(?:=|[ \t]+))"
    r"(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)"
)


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


def _publish_is_exempt(cmd):
    """True only if every publish invocation on the line carries --dry-run."""
    for m in PUBLISH_RE.finditer(cmd):
        tail = re.split(r"[;&|\n]", cmd[m.end() :], maxsplit=1)[0]
        if not DRY_RUN_RE.search(tail):
            return False
    return True


def _resolve(target, base):
    """[target] taken from [base]; None when it is built from a variable."""
    if len(target) > 1 and target[0] in "\"'" and target[-1] == target[0]:
        target = target[1:-1]
    if "$" in target or "`" in target:
        return None
    target = os.path.expanduser(target)
    return target if os.path.isabs(target) else os.path.join(base, target)


def publish_dir(cmd, payload):
    """Where the publish will run, or None when that cannot be determined.

    Only `cd`s BEFORE the publish count; one after it changes nothing. Then the
    publish's own `-C`/`--directory` applies. An unresolvable target (a
    variable, `cd -`, a bare `cd`, `pushd`/`popd`) yields None rather than a
    guess — asking the right question of the wrong directory is the bug this
    replaced. Not parsed: a `cd` inside a subshell that closes before the
    publish, as in `(cd x) && dart pub publish`.
    """
    base = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    first = PUBLISH_RE.search(cmd)
    limit = first.start() if first else len(cmd)

    if any(m.start() < limit for m in OPAQUE_CD_RE.finditer(cmd)):
        return None
    for m in CD_RE.finditer(cmd):
        if m.start() >= limit:
            break
        base = _resolve(m.group(1), base)
        if base is None:
            return None

    if first:
        args = re.split(r"[;&|\n]", cmd[first.end() :], maxsplit=1)[0]
        named = PUB_DIR_RE.search(args)
        if named:
            base = _resolve(named.group(1), base)
            if base is None:
                return None

    return os.path.normpath(base)


def _located(cmd, payload):
    """(repo_root, package_prefix, label) for the package being published.

    `package_prefix` is repo-relative and ends in '/' — or is '' when the
    package IS the repository root, which is what every single-package repo
    looks like.
    """
    where = publish_dir(cmd, payload)
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
        '  README surface, re-run with RELEASE_SKIP_DOCS="<reason>" in the command.'
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

    if not PUBLISH_RE.search(cmd):
        return 0
    if _publish_is_exempt(cmd):
        return 0
    if SKIP_RE.search(cmd):
        return 0  # explicit, reasoned opt-out

    try:
        root, prefix, label = _located(cmd, payload)
        problem = _doc_problem(root, prefix, label)
    except (GitUnavailable, OSError) as e:
        sys.stderr.write(
            f"BLOCKED: cannot verify docs shipped with this release — {e}\n"
            "A publish is irreversible; an unverifiable state is not a safe one.\n"
        )
        return 2

    if problem is None:
        return 0

    sys.stderr.write(
        "BLOCKED: release is missing its docs.\n"
        f"  repository: {root}\n  - "
        + problem
        + "\n(guard: .claude/hooks/guard-release-docs.py)\n"
    )
    return 2


# (command, matches_publish, is_exempt) — matching-rule cases only; the git-based
# doc check is exercised on the live repo, not here.
_TESTS = [
    ("dart pub publish --force", True, False),
    ("cd packages/flutter_edge_ai_agent && dart pub publish", True, False),
    ("cd packages/x\ndart pub publish", True, False),  # multiline was a guard-publish bypass
    ("timeout 900 dart pub publish", True, False),  # wrapper was a bypass
    ("dart pub publish --dry-run", True, True),
    ("dart pub publish --dry-run && dart pub publish", True, False),
    ('RELEASE_SKIP_DOCS="x" dart pub publish', True, False),  # skip handled in main, not exempt
    ("git push origin main", False, False),
    ('grep -r "dart pub publish" docs/', False, False),
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


def _self_test():
    bad = 0
    for cmd, want_match, want_exempt in _TESTS:
        got_match = bool(PUBLISH_RE.search(cmd))
        got_exempt = got_match and _publish_is_exempt(cmd)
        if got_match != want_match or got_exempt != want_exempt:
            bad += 1
            print(
                f"  FAIL {cmd!r}: match={got_match}(want {want_match}) "
                f"exempt={got_exempt}(want {want_exempt})"
            )

    for payload, cmd, want in _DIR_TESTS:
        got = publish_dir(cmd, payload)
        if got != want:
            bad += 1
            print(f"  FAIL want_dir={want!r} got={got!r}  {cmd!r}")

    # skip must be in command position, not inside an echo/grep
    assert SKIP_RE.search('RELEASE_SKIP_DOCS="reason" dart pub publish'), "skip parse"
    assert not SKIP_RE.search('echo RELEASE_SKIP_DOCS=note && dart pub publish'), (
        "skip must not fire from an echo of the string"
    )

    total = len(_TESTS) + len(_DIR_TESTS)
    print(f"  {total - bad}/{total} pass; parse asserts ok")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
