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
        if re.search(r"pub\s+publish", cmd):
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

    unreadable = _unreadable(cmd, "guard-release-registry.py")
    if unreadable:
        sys.stderr.write(unreadable)
        return 2
    if publish_command is None:
        return 0
    # Every publish of the command is checked, not the first: a train
    # `cd a && dart pub publish && cd ../b && dart pub publish` ships both.
    # A dry run, or a publish with its own reasoned RELEASE_SKIP_REGISTRY,
    # needs nothing.
    try:
        checked = _checked(cmd, payload, "RELEASE_SKIP_REGISTRY")
    except publish_command.PublishUnclear as e:
        sys.stderr.write(
            f"BLOCKED: this command holds `pub publish`, but {e}.\n"
            "Write the publish plainly (`cd <package> && dart pub publish`).\n"
            "(guard: .claude/hooks/guard-release-registry.py)\n"
        )
        return 2
    for p in checked:
        try:
            root, prefix, label = _located(p)
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
# publish_command reads, None when it must block the command as unreadable;
# to check leaves out dry runs and publishes with their own reasoned skip.
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
    ("FOO=$(a $(b) c) dart pub publish", 1, 1),
    ("FOO=$(printf ')') dart pub publish", 1, 1),
    ("fvm dart pub publish", 1, 1),
    ("sudo dart pub publish", 1, 1),
    ('bash -c "dart pub publish"', 1, 1),
    ('RELEASE_SKIP_REGISTRY=r bash -c "dart pub publish"', 1, 0),
    ("xargs dart pub publish", None, None),
    ("cat <<'EOF'\ndart pub publish\nEOF", 0, 0),
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
    bad = list(publish_command.self_test())
    for cmd, want_found, want_checked in _TESTS:
        try:
            found = len(publish_command.publishes(cmd, "/r"))
            checked = len(_checked(cmd, {"cwd": "/r"}, "RELEASE_SKIP_REGISTRY"))
        except publish_command.PublishUnclear:
            found = checked = None
        if (found, checked) != (want_found, want_checked):
            bad.append(f"{cmd!r}: found={found} checked={checked}")
        if want_found is None and _run_main(cmd, "/r")[0] != 2:
            bad.append(f"{cmd!r}: unreadable, not blocked")
    for cmd, want in _DIR_TESTS:
        got = [p.directory for p in _checked(cmd, {"cwd": "/r"}, "RELEASE_SKIP_REGISTRY")]
        if got != [os.path.normpath(w) for w in want]:
            bad.append(f"publish_dir {cmd!r}: {got!r}")
    bad += _end_to_end()
    for line in bad:
        print(f"  FAIL {line}")
    total = len(_TESTS) + len(_DIR_TESTS) + 11 + len(publish_command._CASES)
    print(f"  {total - len(bad)}/{total} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
