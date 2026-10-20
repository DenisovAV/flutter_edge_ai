#!/usr/bin/env python3
"""Block `dart pub publish` of a package whose model catalog is not release-ready.

`flutter_edge_ai_litertlm` and `flutter_edge_ai_speech` ship catalogs generated
from model_registry/. Before either is published, `registry.dart release-check
<package>` (tool/model_registry) must pass:
  - the registry passes `check`, and every generated file is current;
  - published/<package>/<version>.json holds the frozen fields this version
    ships (write it with `dart run bin/registry.dart freeze <package>`), so a
    later registry change cannot silently change what this release installs;
  - every cell release_critical.yaml lists for the package is verified: a run
    recorded under model_registry/evidence/ on the native build the package
    ships, since that build or the package's minor version last moved.

The owner chose a hook over a checklist line for this (a checklist advises, a
hook refuses — the same lesson as guard-publish.py and guard-release-docs.py).

Override for a release that cannot have the runs (say why) by putting
`RELEASE_SKIP_REGISTRY=<reason>` in the command.

Fail-closed: if the package, the repository or the tool cannot be found, or
the check cannot run, BLOCK — an irreversible publish in an unknown state is
not a safe one.

Exit 0 allows, exit 2 blocks with the reason on stderr.
Run `python3 guard-release-registry.py --self-test` to check the matching rules.
"""
import json
import os
import re
import subprocess
import sys

# The packages whose published archive carries a generated catalog.
CATALOG_PACKAGES = {"flutter_edge_ai_litertlm", "flutter_edge_ai_speech"}

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
# RELEASE_SKIP_REGISTRY must sit in command position (an env assignment prefix),
# not merely appear in an echo/grep of the string.
SKIP_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*(?:\w+=\S+\s+)*RELEASE_SKIP_REGISTRY=", re.MULTILINE
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




def _package_name(root, prefix):
    path = os.path.join(root, prefix, "pubspec.yaml")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"name:\s*(\S+)", line)
            if m:
                return m.group(1)
    raise GitUnavailable(f"no name: in {prefix}pubspec.yaml")


def _release_check(root, name):
    """None when `release-check` passes, else the reason to block."""
    tool = os.path.join(root, "tool", "model_registry")
    if not os.path.isfile(os.path.join(tool, "bin", "registry.dart")):
        raise GitUnavailable(f"no tool/model_registry in {root}")
    try:
        r = subprocess.run(
            ["dart", "run", "bin/registry.dart", "release-check", name],
            cwd=tool,
            capture_output=True,
            text=True,
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GitUnavailable(f"registry.dart release-check: {e}") from e
    if r.returncode == 0:
        return None
    out = (r.stdout + r.stderr).strip().splitlines()
    return "\n    ".join(out[-40:])


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except Exception as e:
        sys.stderr.write(
            f"BLOCKED: guard-release-registry could not read the hook payload ({e!r}).\n"
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
        name = _package_name(root, prefix)
        if name not in CATALOG_PACKAGES:
            return 0
        problem = _release_check(root, name)
    except (GitUnavailable, OSError) as e:
        sys.stderr.write(
            f"BLOCKED: cannot verify the model registry for this release — {e}\n"
            "A publish is irreversible; an unverifiable state is not a safe one.\n"
        )
        return 2

    if problem is None:
        return 0

    sys.stderr.write(
        f"BLOCKED: {name} is not release-ready by the model registry.\n"
        f"  repository: {root}\n"
        f"    {problem}\n"
        "  Record the missing runs (registry_evidence.dart + `registry.dart\n"
        "  evidence`), run `registry.dart freeze <package>`, or re-run with\n"
        '  RELEASE_SKIP_REGISTRY="<reason>" in the command.\n'
        "(guard: .claude/hooks/guard-release-registry.py)\n"
    )
    return 2


_TESTS = [
    ("dart pub publish --force", True, False),
    ("cd packages/flutter_edge_ai_speech && dart pub publish", True, False),
    ("cd packages/x\ndart pub publish", True, False),
    ("timeout 900 dart pub publish", True, False),
    ("dart pub publish --dry-run", True, True),
    ("dart pub publish --dry-run && dart pub publish", True, False),
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
            print(f"  FAIL {cmd!r}: match={got_match} exempt={got_exempt}")
    assert SKIP_RE.search('RELEASE_SKIP_REGISTRY="no device" dart pub publish')
    assert not SKIP_RE.search("echo RELEASE_SKIP_REGISTRY=x && dart pub publish")
    want = os.path.normpath("/r/packages/flutter_edge_ai_litertlm")
    got = publish_dir("cd packages/flutter_edge_ai_litertlm && dart pub publish", {"cwd": "/r"})
    if got != want:
        bad += 1
        print(f"  FAIL publish_dir {got!r}")
    print(f"  {len(_TESTS) + 1 - bad}/{len(_TESTS) + 1} pass; parse asserts ok")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
