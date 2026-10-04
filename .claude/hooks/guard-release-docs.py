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
its own pub.dev-facing `packages/X/README.md` did NOT. The README specifically —
a `website/content/docs/` edit is deliberately NOT accepted as a substitute:
website docs aren't package-scoped, so a sibling package's website change (batch
release) or a website-only-but-README-skipped change (the agent 0.2.3 miss this
hook was built for) would otherwise pass. website/README both belong in the
release, but only README is enforceable per-package here; the Step-12b website
docs are enforced by review + the DoD checklist.

This range/boundary logic is only exact when HEAD == the release commit — which is
always true when this PreToolUse hook actually fires (at `dart pub publish` time).
It is NOT a general retroactive audit.

Override for a genuine code-only release with no README surface (rare) by putting
`RELEASE_SKIP_DOCS=<reason>` in the command, e.g.
  RELEASE_SKIP_DOCS="internal refactor, no public API/behavior change" dart pub publish

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
# a `cd\n dart pub publish` block must still match).
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
# `packages/<name>` as a path segment — used for both `cd packages/<name>` in the
# command AND the hook payload's cwd (a bare `dart pub publish` run from the
# package dir carries no `cd`, so cwd is the fallback).
PKG_SEG_RE = re.compile(r"(?:^|/)packages/([A-Za-z0-9_]+)(?:/|$)")
CD_PKG_RE = re.compile(r"cd\s+(\S*packages/[A-Za-z0-9_]+)")


class GitUnavailable(RuntimeError):
    """git could not be consulted — treated as a block, never as 'clean'."""


def git(*args):
    try:
        r = subprocess.run(
            ["git", "-C", os.environ.get("CLAUDE_PROJECT_DIR", "."), *args],
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


def _package_from(cmd, cwd):
    """Which packages/<name> is being published. None if undeterminable.

    Prefer the LAST `cd .../packages/<name>` on the command (it reflects the
    effective cwd of the publish); fall back to the payload cwd, which is where a
    bare `dart pub publish` (no `cd`) actually runs — that is the shape the
    release skill's Step 10 documents, so it must resolve, not block.
    """
    last = None
    for m in CD_PKG_RE.finditer(cmd):
        last = m.group(1)
    if last:
        seg = PKG_SEG_RE.search(last)
        if seg:
            return seg.group(1)
    if cwd:
        seg = PKG_SEG_RE.search(cwd)
        if seg:
            return seg.group(1)
    return None


def _current_version(pkg):
    root = os.environ.get("CLAUDE_PROJECT_DIR", ".")
    path = os.path.join(root, "packages", pkg, "pubspec.yaml")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"version:\s*(\S+)", line)
            if m:
                return m.group(1)
    raise GitUnavailable(f"no version: in packages/{pkg}/pubspec.yaml")


def _doc_problem(pkg):
    """Return a block-reason string, or None if the release's docs are fine."""
    version = _current_version(pkg)
    # The commit that set the CURRENT version is the release boundary. -S finds
    # where the exact `version: V` string entered pubspec.yaml.
    boundary = git(
        "log", "-1", "--format=%H", "-S", f"version: {version}",
        "--", f"packages/{pkg}/pubspec.yaml",
    )
    if not boundary:
        raise GitUnavailable(
            f"cannot locate the commit that set version {version} for {pkg}"
        )
    # Files changed in boundary..HEAD, plus the boundary commit itself.
    changed = set(
        git("diff", "--name-only", f"{boundary}~1", "HEAD").splitlines()
    )
    lib_prefix = f"packages/{pkg}/lib/"
    code_changed = any(f.startswith(lib_prefix) for f in changed)
    if not code_changed:
        return None  # docs-only / no public code change → nothing to enforce

    # Require the package's OWN README (the pub.dev landing page). A global
    # website/content/docs/ edit is NOT a substitute: the motivating miss (agent
    # 0.2.3) updated website/agent.md but skipped the README and had to re-ship as
    # 0.2.4. Accepting any website edit would also let a co-released package in a
    # batch (e.g. "core + speech") mask another package whose README was skipped.
    # README is package-scoped, so it can't be borrowed from a sibling.
    readme = f"packages/{pkg}/README.md"
    if readme in changed:
        return None

    return (
        f"packages/{pkg}/lib changed since v{version} was set ({boundary[:10]}) "
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
        cwd = payload.get("cwd") or ""
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

    pkg = _package_from(cmd, cwd)
    if pkg is None:
        sys.stderr.write(
            "BLOCKED: guard-release-docs can't tell which package is being "
            "published (no `cd .../packages/<name>` and no packages/<name> cwd).\n"
            "Run the publish from the package dir, or add "
            'RELEASE_SKIP_DOCS="<reason>" if intentional.\n'
        )
        return 2

    try:
        problem = _doc_problem(pkg)
    except (GitUnavailable, OSError) as e:
        sys.stderr.write(
            f"BLOCKED: cannot verify docs shipped with this release — {e}\n"
            "A publish is irreversible; an unverifiable state is not a safe one.\n"
        )
        return 2

    if problem is None:
        return 0

    sys.stderr.write(
        "BLOCKED: release is missing its docs.\n  - "
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
    # package resolution: cd-in-command, cwd-fallback (bare publish), last-cd-wins
    assert _package_from("cd packages/flutter_edge_ai_agent && dart pub publish", "") == (
        "flutter_edge_ai_agent"
    ), "cd parse"
    assert _package_from("dart pub publish", "/repo/packages/flutter_edge_ai") == (
        "flutter_edge_ai"
    ), "bare publish resolves via cwd (Step 10 shape)"
    assert _package_from("dart pub publish", "") is None, "no cd, no cwd -> None"
    assert _package_from(
        "cd packages/flutter_edge_ai && cd packages/flutter_edge_ai_agent && dart pub publish", ""
    ) == "flutter_edge_ai_agent", "last cd wins"
    # skip must be in command position, not inside an echo/grep
    assert SKIP_RE.search('RELEASE_SKIP_DOCS="reason" dart pub publish'), "skip parse"
    assert not SKIP_RE.search('echo RELEASE_SKIP_DOCS=note && dart pub publish'), (
        "skip must not fire from an echo of the string"
    )
    print(f"  {len(_TESTS) - bad}/{len(_TESTS)} match-rule cases pass; parse asserts ok")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
