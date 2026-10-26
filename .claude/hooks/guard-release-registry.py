#!/usr/bin/env python3
"""Block `dart pub publish` of a package whose model catalog is not release-ready.

`flutter_edge_ai_litertlm` and `flutter_edge_ai_speech` ship catalogs generated
from model_registry/. Before either is published, `registry.dart release-check
<package>` (tool/model_registry) must have passed at this HEAD:
  - the registry passes `check`, and every generated file is current;
  - published/<package>/<version>.json holds the frozen fields this version
    ships (write it with `dart run bin/registry.dart freeze <package>`), so a
    later registry change cannot silently change what this release installs;
  - every cell release_critical.yaml lists for the package is verified: a run
    recorded under model_registry/evidence/ on the native build the package
    ships, since that build or the package's minor version last moved.

The hook does not run the check itself: a PreToolUse hook that executes
repository code would run it before the command is approved. It reads the
stamp `release-check` writes on success
(tool/model_registry/.dart_tool/release_check/<package>-<version>.ok, the HEAD
it passed at) and asks git only: the stamp's HEAD is HEAD, and nothing under
model_registry/, tool/model_registry/ or the package has changed since.

The owner chose a hook over a checklist line for this (a checklist advises, a
hook refuses — the same lesson as guard-publish.py and guard-release-docs.py).

Override for a release that cannot have the runs (say why) by putting
`RELEASE_SKIP_REGISTRY="<reason>"` in front of that publish
(`RELEASE_SKIP_REGISTRY="no device" dart pub publish`). It covers that one
publish only; on another command of the chain, exported earlier, or with an
empty reason it is not an override. Every publish of a command is checked.

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

# A shell assignment value: quoted parts (which may hold spaces) and bare
# characters, possibly empty. One character per repetition, never `[...]+`
# inside the `*`, so a long line that is no publish cannot backtrack for ever.
# A command substitution (`$(pwd)`, also nested, or backticks) is part of a
# value too: without it `FOO=$(pwd) dart pub publish` went unseen.
_VALUE = r"(?:\"[^\"]*\"|'[^']*'|\$\([^)]*\)+|`[^`]*`|[^\s\"'`;&|()])*"
_ASSIGN = r"\w+=" + _VALUE
# Mirror guard-publish.py's command-position matcher (MULTILINE is load-bearing:
# a `cd` line followed by the publish on the next line must still match).
# `prefix` is the publish's own assignments and wrappers: only a
# RELEASE_SKIP_REGISTRY there reaches the publish.
PUBLISH_RE = re.compile(
    r"(?:^|[;&|(]|&&|\|\|)\s*"
    r"(?P<prefix>(?:" + _ASSIGN + r"\s+)*"
    r"(?:(?:timeout|nice|env|command|stdbuf)\s+(?:" + _ASSIGN + r"|\S+)\s+"
    r"(?:" + _ASSIGN + r"\s+)*)*)"
    r"(?:dart|flutter)\s+pub\s+publish\b",
    re.MULTILINE,
)
DRY_RUN_RE = re.compile(r"(?<![\w-])--dry-run(?![\w-])")
SKIP_ASSIGN_RE = re.compile(r"(?<!\S)RELEASE_SKIP_REGISTRY=(" + _VALUE + r")")
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


def _args(cmd, match):
    """The publish's own arguments: up to the next separator."""
    return re.split(r"[;&|\n]", cmd[match.end() :], maxsplit=1)[0]


def _is_dry_run(cmd, match):
    return bool(DRY_RUN_RE.search(_args(cmd, match)))


def _skip_reason(match):
    """The RELEASE_SKIP_REGISTRY reason this publish itself carries, or None.

    Only an assignment in the publish's own prefix counts: one on another
    command of the chain (`RELEASE_SKIP_REGISTRY=x echo && dart pub publish`)
    never reaches the publish. An empty or blank reason is no reason.
    """
    for m in SKIP_ASSIGN_RE.finditer(match.group("prefix")):
        reason = re.sub(r"[\"']", "", m.group(1)).strip()
        if reason:
            return reason
    return None


def _checked_publishes(cmd):
    """Every publish in [cmd] that ships and is not skipped with a reason."""
    return [
        m
        for m in PUBLISH_RE.finditer(cmd)
        if not _is_dry_run(cmd, m) and _skip_reason(m) is None
    ]


def _resolve(target, base):
    """[target] taken from [base]; None when it is built from a variable."""
    if len(target) > 1 and target[0] in "\"'" and target[-1] == target[0]:
        target = target[1:-1]
    if "$" in target or "`" in target:
        return None
    target = os.path.expanduser(target)
    return target if os.path.isabs(target) else os.path.join(base, target)


def publish_dir(cmd, payload, match=None):
    """Where [match] (the first publish by default) will run, or None when that
    cannot be determined.

    Only `cd`s BEFORE the publish count; one after it changes nothing. Then the
    publish's own `-C`/`--directory` applies. An unresolvable target (a
    variable, `cd -`, a bare `cd`, `pushd`/`popd`) yields None rather than a
    guess — asking the right question of the wrong directory is the bug this
    replaced. Not parsed: a `cd` inside a subshell that closes before the
    publish, as in `(cd x) && dart pub publish`.
    """
    base = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    first = match or PUBLISH_RE.search(cmd)
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
        named = PUB_DIR_RE.search(_args(cmd, first))
        if named:
            base = _resolve(named.group(1), base)
            if base is None:
                return None

    return os.path.normpath(base)


def _located(cmd, payload, match):
    """(repo_root, package_prefix, label) for the package [match] publishes.

    `package_prefix` is repo-relative and ends in '/' — or is '' when the
    package IS the repository root, which is what every single-package repo
    looks like.
    """
    where = publish_dir(cmd, payload, match)
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


def _version(root, prefix):
    path = os.path.join(root, prefix, "pubspec.yaml")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"version:\s*(\S+)", line)
            if m:
                return m.group(1)
    raise GitUnavailable(f"no version: in {prefix}pubspec.yaml")


def _release_check(root, prefix, name):
    """None when release-check passed at this HEAD, else the reason to block."""
    version = _version(root, prefix)
    stamp = os.path.join(
        root, "tool", "model_registry", ".dart_tool", "release_check",
        f"{name}-{version}.ok",
    )
    run = (
        f"run `dart run bin/registry.dart release-check {name}` in "
        "tool/model_registry"
    )
    try:
        with open(stamp, encoding="utf-8") as fh:
            passed = json.load(fh)
    except (OSError, ValueError):
        return f"release-check has not passed for {name} {version}: {run}"
    head = git(root, "rev-parse", "HEAD")
    if passed.get("head") != head:
        return (
            f"release-check passed at {str(passed.get('head'))[:10]}, HEAD is "
            f"{head[:10]}: {run} again"
        )
    changed = git(
        root, "status", "--porcelain", "--", "model_registry",
        "tool/model_registry", prefix.rstrip("/") or ".",
    )
    if changed:
        return f"uncommitted changes since release-check:\n    {changed}"
    return None


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except Exception as e:
        sys.stderr.write(
            f"BLOCKED: guard-release-registry could not read the hook payload ({e!r}).\n"
        )
        return 2

    # Every publish of the command is checked, not the first: a train
    # `cd a && dart pub publish && cd ../b && dart pub publish` ships both.
    # A dry run, or a publish with its own reasoned RELEASE_SKIP_REGISTRY,
    # needs nothing.
    for match in _checked_publishes(cmd):
        try:
            root, prefix, label = _located(cmd, payload, match)
            name = _package_name(root, prefix)
            if name not in CATALOG_PACKAGES:
                continue
            problem = _release_check(root, prefix, name)
        except Exception as e:  # noqa: BLE001 — any surprise blocks
            sys.stderr.write(
                f"BLOCKED: cannot verify the model registry for this release — {e}\n"
                "A publish is irreversible; an unverifiable state is not a safe one.\n"
            )
            return 2
        if problem is not None:
            return _blocked(name, root, problem)
    return 0


def _blocked(name, root, problem):
    sys.stderr.write(
        f"BLOCKED: {name} is not release-ready by the model registry.\n"
        f"  repository: {root}\n"
        f"    {problem}\n"
        "  Record the missing runs (registry_evidence.dart + `registry.dart\n"
        "  evidence`), run `registry.dart freeze <package>`, or re-run with\n"
        '  RELEASE_SKIP_REGISTRY="<reason>" in front of that publish.\n'
        "(guard: .claude/hooks/guard-release-registry.py)\n"
    )
    return 2


# (command, publishes found, publishes to check): found counts every publish
# the matcher sees, which guard-publish.py must see as well; to check leaves
# out dry runs and publishes with their own reasoned skip.
_TESTS = [
    ("dart pub publish --force", 1, 1),
    ("cd packages/flutter_edge_ai_speech && dart pub publish", 1, 1),
    ("cd packages/x\ndart pub publish", 1, 1),
    ("timeout 900 dart pub publish", 1, 1),
    ("dart pub publish --dry-run", 1, 0),
    ("dart pub publish --dry-run && dart pub publish", 2, 1),
    ("git push origin main", 0, 0),
    ('grep -r "dart pub publish" docs/', 0, 0),
    # The documented override: a quoted reason with a space.
    ('RELEASE_SKIP_REGISTRY="no device" dart pub publish --force', 1, 0),
    ("RELEASE_SKIP_REGISTRY='no device' X=1 dart pub publish", 1, 0),
    ("RELEASE_SKIP_REGISTRY=nodevice dart pub publish", 1, 0),
    ('env RELEASE_SKIP_REGISTRY="no device" dart pub publish', 1, 0),
    # An empty or blank reason is no override.
    ("RELEASE_SKIP_REGISTRY= dart pub publish", 1, 1),
    ('RELEASE_SKIP_REGISTRY="" dart pub publish', 1, 1),
    ('RELEASE_SKIP_REGISTRY="  " dart pub publish', 1, 1),
    # Other prefixes still mean a publish.
    ("X=1 dart pub publish", 1, 1),
    ('PUB_HOSTED_URL="https://a b" dart pub publish', 1, 1),
    ("a && dart pub publish", 1, 1),
    ("a; dart pub publish", 1, 1),
    ("FOO=$(pwd) dart pub publish", 1, 1),
    ("FOO=$(a $(b)) dart pub publish", 1, 1),
    ("FOO=`pwd` dart pub publish", 1, 1),
    ("RELEASE_SKIP_REGISTRY=$(echo r) dart pub publish", 1, 0),
    # The skip on another command of the chain never reaches the publish.
    ("RELEASE_SKIP_REGISTRY=x echo hi && dart pub publish", 1, 1),
    ("echo RELEASE_SKIP_REGISTRY=x && dart pub publish", 1, 1),
    ("export RELEASE_SKIP_REGISTRY=x; dart pub publish", 1, 1),
    # Every publish of a chain, each with its own skip.
    ("cd a && dart pub publish -f && cd ../b && dart pub publish -f", 2, 2),
    ('RELEASE_SKIP_REGISTRY="r" dart pub publish -C a; dart pub publish -C b', 2, 1),
]

# (command, directory of each checked publish), cwd /r.
_DIR_TESTS = [
    (
        "cd packages/a && dart pub publish -f && cd ../b && dart pub publish -f",
        ["/r/packages/a", "/r/packages/b"],
    ),
    ("dart pub publish -C a; dart pub publish -C b", ["/r/a", "/r/b"]),
    ("cd packages/flutter_edge_ai_litertlm && dart pub publish", ["/r/packages/flutter_edge_ai_litertlm"]),
]


def _run_main(cmd, cwd):
    """main() on [cmd] as the hook payload; (exit code, stderr)."""
    import contextlib
    import io

    payload = json.dumps({"tool_input": {"command": cmd}, "cwd": cwd})
    err = io.StringIO()
    stdin = sys.stdin
    sys.stdin = io.StringIO(payload)
    try:
        with contextlib.redirect_stderr(err):
            code = main()
    finally:
        sys.stdin = stdin
    return code, err.getvalue()


def _end_to_end():
    """main() against a scratch repository with a catalog package; the failures."""
    import tempfile

    bad = []
    with tempfile.TemporaryDirectory() as repo:
        for name, version in [("flutter_edge_ai", "2.0.0"), ("flutter_edge_ai_litertlm", "1.0.0")]:
            os.makedirs(os.path.join(repo, "packages", name))
            with open(os.path.join(repo, "packages", name, "pubspec.yaml"), "w") as fh:
                fh.write(f"name: {name}\nversion: {version}\n")
        with open(os.path.join(repo, ".gitignore"), "w") as fh:
            fh.write(".dart_tool/\n")
        for args in (
            ["init", "-q"],
            ["add", "-A"],
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "t"],
        ):
            git(repo, *args)
        core = "dart pub publish -f -C packages/flutter_edge_ai"
        lite = "dart pub publish -f -C packages/flutter_edge_ai_litertlm"
        cases = [
            (core, 0),
            (lite, 2),
            (f"{core} && {lite}", 2),  # the second publish was unchecked
            (f"cd packages/flutter_edge_ai && dart pub publish -f && cd ../flutter_edge_ai_litertlm && dart pub publish -f", 2),
            (f'RELEASE_SKIP_REGISTRY="no device" {lite}', 0),
            (f'{core} && RELEASE_SKIP_REGISTRY="no device" {lite}', 0),
            (f"RELEASE_SKIP_REGISTRY= {lite}", 2),
            (f"RELEASE_SKIP_REGISTRY=x echo hi && {lite}", 2),
            (f"X=1 {lite}", 2),
        ]
        stamp_dir = os.path.join(repo, "tool", "model_registry", ".dart_tool", "release_check")
        os.makedirs(stamp_dir)
        stamp = os.path.join(stamp_dir, "flutter_edge_ai_litertlm-1.0.0.ok")
        for cmd, want in cases:
            got, err = _run_main(cmd, repo)
            if got != want:
                bad.append(f"main {cmd!r}: exit {got}, want {want} {err.strip()[:120]}")
        # The positive control: a stamp at HEAD lets the publish through.
        with open(stamp, "w") as fh:
            json.dump({"head": git(repo, "rev-parse", "HEAD")}, fh)
        if _run_main(lite, repo)[0] != 0:
            bad.append("main: a stamp at HEAD still blocks")
        # A stamp that is JSON but no object blocks instead of crashing open.
        with open(stamp, "w") as fh:
            json.dump([1], fh)
        if _run_main(lite, repo)[0] != 2:
            bad.append("main: a list stamp does not block")
    return bad


def _self_test():
    bad = []
    for cmd, want_found, want_checked in _TESTS:
        found = len(list(PUBLISH_RE.finditer(cmd)))
        checked = len(_checked_publishes(cmd))
        if (found, checked) != (want_found, want_checked):
            bad.append(f"{cmd!r}: found={found} checked={checked}")
    for cmd, want in _DIR_TESTS:
        got = [publish_dir(cmd, {"cwd": "/r"}, m) for m in _checked_publishes(cmd)]
        if got != [os.path.normpath(w) for w in want]:
            bad.append(f"publish_dir {cmd!r}: {got!r}")
    bad += _end_to_end()
    for line in bad:
        print(f"  FAIL {line}")
    total = len(_TESTS) + len(_DIR_TESTS) + 11
    print(f"  {total - len(bad)}/{total} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
