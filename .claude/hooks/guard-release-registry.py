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
_IMPORT_ERROR = None
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


def _loosely_publishes(cmd):
    """Whether [cmd] may hold a publish, read loosely and in linear time:
    publish_command's reading when it loaded; else `pub` (or `packages`) and
    a publish word anywhere, quotes and backslashes dropped, and any `$'…'`
    beside a `pub` (its escapes could spell the rest)."""
    if publish_command is not None:
        return publish_command.mentions_publish(cmd)
    text = re.sub(r"[\"'\\]", "", cmd)
    pub = re.search(r"\b(?:pub|packages)\b", text)
    return bool(pub and (re.search(r"\b(?:publish|lish|lush)\b", text) or "$'" in cmd))


def _unreadable(cmd, hook):
    """The block for a command this hook cannot read; None when it can."""
    if publish_command is None:
        if _loosely_publishes(cmd):
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




# A top-level YAML scalar, bare or quoted: `name: x`, `name: 'x'`, `name: "x"`.
def _top_level(field):
    return re.compile(rf"""{field}:\s*(?:'([^']*)'|"([^"]*)"|([^\s#'"]+))""")


def _pubspec_value(root, prefix, field):
    path = os.path.join(root, prefix, "pubspec.yaml")
    pattern = _top_level(field)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = pattern.match(line)
            if m:
                return next(g for g in m.groups() if g is not None)
    raise GitUnavailable(f"no {field}: in {prefix}pubspec.yaml")


def _package_name(root, prefix):
    name = _pubspec_value(root, prefix, "name")
    # A tag, an anchor or a block scalar (`!!str x`, `&a x`, `>-`) would read
    # as some other name and let the publish through unchecked.
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", name):
        raise GitUnavailable(
            f"the name in {prefix}pubspec.yaml reads as {name!r}, not a package "
            "name; write it plainly"
        )
    return name


def _version(root, prefix):
    return _pubspec_value(root, prefix, "version")


def _catalog_packages(root):
    """CATALOG_PACKAGES and every `package:` a registry model names.

    A package that gains a catalog is guarded as soon as a model names it,
    not when someone remembers this list.
    """
    names = set(CATALOG_PACKAGES)
    models = os.path.join(root, "model_registry", "models")
    if os.path.isdir(models):
        pattern = _top_level("package")
        for entry in sorted(os.listdir(models)):
            if not entry.endswith(".yaml"):
                continue
            with open(os.path.join(models, entry), encoding="utf-8") as fh:
                for line in fh:
                    m = pattern.match(line)
                    if m:
                        names.add(next(g for g in m.groups() if g is not None))
    return names


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
    # An example app's pubspec.lock is rewritten by any `pub get` and is not
    # what the catalog ships; it is left out, as release-check leaves it out.
    # Every untracked file by name, as release-check lists them, not only its
    # new directory.
    changed = git(
        root, "status", "--porcelain", "--untracked-files=all", "--",
        "model_registry",
        "tool/model_registry", prefix.rstrip("/") or ".",
        ":(exclude,glob)**/example/pubspec.lock",
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
    # An accepted override is said where the session shows it — a
    # PreToolUse hook's stderr is not shown when it allows — so the log of
    # the release keeps why.
    skipped = []
    for p in publish_command.publishes(cmd, _cwd(payload)):
        reason = None if p.dry_run else p.skip_reason("RELEASE_SKIP_REGISTRY")
        if reason is not None:
            skipped.append(
                f"the registry check is skipped for "
                f"{p.directory or 'this publish'}: {reason}"
            )
    for p in checked:
        try:
            root, prefix, label = _located(p)
            name = _package_name(root, prefix)
            if name not in _catalog_packages(root):
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
    if skipped:
        print(json.dumps({"systemMessage": "guard-release-registry: " + "; ".join(skipped)}))
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
    """main() on [cmd] as the hook payload; (exit code, stderr + stdout)."""
    import contextlib
    import io

    payload = json.dumps({"tool_input": {"command": cmd}, "cwd": cwd})
    err = io.StringIO()
    out = io.StringIO()
    stdin = sys.stdin
    sys.stdin = io.StringIO(payload)
    try:
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            code = main()
    finally:
        sys.stdin = stdin
    return code, err.getvalue() + out.getvalue()


def _end_to_end():
    """main() against a scratch repository with a catalog package; the failures."""
    import tempfile

    bad = []
    with tempfile.TemporaryDirectory() as repo:
        # litertlm's name is quoted, as YAML allows; extra is a catalog
        # package only because a registry model names it.
        for name, written, version in [
            ("flutter_edge_ai", "flutter_edge_ai", "2.0.0"),
            ("flutter_edge_ai_litertlm", "'flutter_edge_ai_litertlm'", "'1.0.0'"),
            ("flutter_edge_ai_extra", "flutter_edge_ai_extra", "0.1.0"),
        ]:
            os.makedirs(os.path.join(repo, "packages", name))
            with open(os.path.join(repo, "packages", name, "pubspec.yaml"), "w") as fh:
                fh.write(f"name: {written}\nversion: {version}\n")
        os.makedirs(os.path.join(repo, "model_registry", "models"))
        with open(os.path.join(repo, "model_registry", "models", "x.yaml"), "w") as fh:
            fh.write("id: x\npackage: flutter_edge_ai_extra\n")
        with open(os.path.join(repo, ".gitignore"), "w") as fh:
            fh.write(".dart_tool/\n")
        example = os.path.join(repo, "packages", "flutter_edge_ai_litertlm", "example")
        os.makedirs(example)
        with open(os.path.join(example, "pubspec.lock"), "w") as fh:
            fh.write("packages: {}\n")
        with open(os.path.join(repo, "packages", "flutter_edge_ai_litertlm", "lib.dart"), "w") as fh:
            fh.write("// v1\n")
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
            ("dart pub publish -f -C packages/flutter_edge_ai_extra", 2),
        ]
        stamp_dir = os.path.join(repo, "tool", "model_registry", ".dart_tool", "release_check")
        os.makedirs(stamp_dir)
        stamp = os.path.join(stamp_dir, "flutter_edge_ai_litertlm-1.0.0.ok")
        for cmd, want in cases:
            got, err = _run_main(cmd, repo)
            if got != want:
                bad.append(f"main {cmd!r}: exit {got}, want {want} {err.strip()[:120]}")
        # Each check below adds one to [extra], so the total counts them.
        extra = 0
        # An accepted override says why, as a systemMessage the session shows.
        said = _run_main(f'RELEASE_SKIP_REGISTRY="no device" {lite}', repo)[1]
        if '"systemMessage"' not in said or "no device" not in said:
            bad.append("main: an accepted override names no reason")
        extra += 1
        # The positive control: a stamp at HEAD lets the publish through.
        with open(stamp, "w") as fh:
            json.dump({"head": git(repo, "rev-parse", "HEAD")}, fh)
        if _run_main(lite, repo)[0] != 0:
            bad.append("main: a stamp at HEAD still blocks")
        extra += 1
        # An example's pubspec.lock that `pub get` rewrote does not block...
        with open(os.path.join(example, "pubspec.lock"), "w") as fh:
            fh.write("packages: {rewritten: true}\n")
        if _run_main(lite, repo)[0] != 0:
            bad.append("main: a rewritten example pubspec.lock blocks")
        extra += 1
        # A name that is not a plain package name blocks.
        tagged = os.path.join(repo, "packages", "tagged")
        os.makedirs(tagged)
        with open(os.path.join(tagged, "pubspec.yaml"), "w") as fh:
            fh.write("name: !!str flutter_edge_ai_litertlm\nversion: 1.0.0\n")
        if _run_main("dart pub publish -f -C packages/tagged", repo)[0] != 2:
            bad.append("main: a tagged pubspec name does not block")
        extra += 1
        # A crash blocks a publish, and only a publish.
        real_main = globals()["main"]
        globals()["main"] = lambda: 1 / 0
        try:
            for cmd, want in (
                (lite, 2),
                ("git status", 0),
                # A newline between `pub` and `publish`, escaped in the JSON.
                ("dart pub \\\npublish -f", 2),
                ("dart pub\npublish -f", 2),
                # Quotes, backslashes and ANSI-C escapes inside the word.
                ("dart pub pu''blish -f", 2),
                ("dart pub pu\\blish -f", 2),
                ("dart pub $'\\x70ublish' -f", 2),
                ("flutter packages publish -f", 2),
            ):
                if _run_guarded(cmd, repo) != want:
                    bad.append(f"main: a crash on {cmd!r} is not exit {want}")
        finally:
            globals()["main"] = real_main
        extra += 1
        # An untracked file in a new directory of the package blocks too.
        os.makedirs(os.path.join(repo, "packages", "flutter_edge_ai_litertlm", "new"))
        with open(os.path.join(repo, "packages", "flutter_edge_ai_litertlm", "new", "x.dart"), "w") as fh:
            fh.write("// new\n")
        if "new/x.dart" not in (_release_check(
            repo, "packages/flutter_edge_ai_litertlm/", "flutter_edge_ai_litertlm"
        ) or ""):
            bad.append("main: an untracked file is not named")
        extra += 1
        # ...any other uncommitted file of the package does.
        with open(os.path.join(repo, "packages", "flutter_edge_ai_litertlm", "lib.dart"), "w") as fh:
            fh.write("// v2\n")
        if _run_main(lite, repo)[0] != 2:
            bad.append("main: an uncommitted package file does not block")
        extra += 1
        # A stamp that is JSON but no object blocks instead of crashing open.
        with open(stamp, "w") as fh:
            json.dump([1], fh)
        if _run_main(lite, repo)[0] != 2:
            bad.append("main: a list stamp does not block")
        extra += 1
    return bad, len(cases) + extra


def _run_guarded(cmd, cwd):
    """_guarded_main() on [cmd] as the hook payload, its stderr kept out of
    the self-test's output; the exit code."""
    import contextlib
    import io

    payload = json.dumps({"tool_input": {"command": cmd}, "cwd": cwd})
    stdin = sys.stdin
    sys.stdin = io.StringIO(payload)
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return _guarded_main()
    finally:
        sys.stdin = stdin


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
    end_to_end_bad, end_to_end_checks = _end_to_end()
    bad += end_to_end_bad
    # Without publish_command, the guard's own loose reading.
    loaded = globals()["publish_command"]
    globals()["publish_command"] = None
    try:
        fallback = [
            ("dart pub -v publish -f", True),
            ("flutter packages publish", True),
            ("dart pub $'\\x70ublish'", True),
            ("bash <<< 'dart pub lish'", True),
            ("git status", False),
        ]
        for cmd, want in fallback:
            if (_unreadable(cmd, "x") is not None) != want:
                bad.append(f"fallback {cmd!r}: blocked={not want}")
    finally:
        globals()["publish_command"] = loaded
    # Linear: a long text of `pub ` words is read at once.
    import time

    started = time.monotonic()
    _may_publish(json.dumps({"tool_input": {"command": "pub " * 20000}}))
    if time.monotonic() - started > 0.5:
        bad.append("the crash-path reading is not linear")
    extra_checks = len(fallback) + 1
    for line in bad:
        print(f"  FAIL {line}")
    total = (
        len(_TESTS) + len(_DIR_TESTS) + end_to_end_checks + extra_checks
        + len(publish_command._CASES)
    )
    print(f"  {total - len(bad)}/{total} pass")
    return 1 if bad else 0


def _may_publish(raw):
    """Whether the hook payload [raw] may hold a publish: judged on the
    decoded command, as main() reads it, never on the JSON text (where an
    escaped newline hides `pub\\npublish`), and loosely (`pu""blish`,
    `$'\\x70ublish'`). An unreadable payload may."""
    try:
        cmd = (json.loads(raw).get("tool_input") or {}).get("command") or ""
        return not isinstance(cmd, str) or _loosely_publishes(cmd)
    except BaseException:  # noqa: BLE001 — unreadable or a reader bug: may publish
        return True


def _guarded_main():
    """main(), failing closed for a publish only.

    The hook runs on every Bash command. A crash on a command whose text
    holds a publish is exit 2 (block), never the exit 1 of a traceback, which
    a PreToolUse hook reads as a non-blocking error; on any other command it
    lets the command through and says why on stderr.
    """
    import io

    try:
        raw = sys.stdin.read()
    except BaseException as e:  # noqa: BLE001 — a payload not read may publish
        sys.stderr.write(
            f"BLOCKED: guard-release-registry could not read the hook payload "
            f"({e!r}).\n"
        )
        return 2
    sys.stdin = io.StringIO(raw)
    try:
        return main()
    except BaseException as e:  # noqa: BLE001 — a surprise blocks a publish
        if not _may_publish(raw):
            sys.stderr.write(
                f"guard-release-registry failed ({e!r}) on a command with no "
                "publish; allowed.\n"
            )
            return 0
        sys.stderr.write(
            f"BLOCKED: guard-release-registry failed ({e!r}); a publish in an "
            "unknown state is not a safe one.\n"
        )
        return 2


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(_guarded_main())
