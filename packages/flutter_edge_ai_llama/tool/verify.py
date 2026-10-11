#!/usr/bin/env python3
"""Independent package gates. Model/device lanes require explicit fixtures."""

import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from threading import Event, Thread

from serve_web_fixture import create_server

PACKAGE = Path(__file__).resolve().parents[1]


def sample_native_apps(directory, stop):
    """Retain three recent read-only thread samples per Apple test process."""
    directory.mkdir(parents=True, exist_ok=True)
    sequence = {}
    while not stop.wait(5):
        try:
            processes = subprocess.run(["ps", "-axo", "pid=,comm="],
                                       capture_output=True, text=True, timeout=5)
            for line in processes.stdout.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) != 2:
                    continue
                pid, executable = fields
                if not pid.isdigit() or not (executable.endswith("/flutter_edge_ai_llama_demo") or executable.endswith("/Runner.app/Runner")):
                    continue
                slot = sequence.get(pid, 0) % 3
                sequence[pid] = slot + 1
                subprocess.run(["sample", pid, "1", "-file", str(directory / f"app-{pid}-{slot}.txt")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            # Diagnostics must not turn a failed runtime test into a success or
            # replace its failure with a sampler/tool availability failure.
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=("contracts", "native", "web", "package", "build", "device"))
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--model-url")
    parser.add_argument("--storage-helper-url")
    parser.add_argument("--platform", choices=("android", "ios", "macos", "windows", "linux", "web"))
    parser.add_argument("--device")
    parser.add_argument("--native-diagnostics", action="store_true",
                        help="Apple runtime lanes: retain recent app thread samples in RUNNER_TEMP")
    parser.add_argument("--core-path", type=Path,
                        help="Package preparation only: validate against this unreleased core; hosted validation remains required before publishing")
    args = parser.parse_args()
    # Resolve PATHEXT on Windows so CreateProcess receives flutter.bat.
    flutter = shutil.which(args.flutter) or args.flutter
    sdk = Path(flutter).parent / ("dart.bat" if os.name == "nt" else "dart")
    dart = str(sdk) if sdk.exists() else "dart"

    def run(command, directory=PACKAGE):
        print("Running:", subprocess.list2cmdline([str(x) for x in command]), flush=True)
        stop = Event()
        monitor = None
        if args.native_diagnostics and len(command) > 1 and command[1] == "test":
            diagnostics = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "edge-ai-native-diagnostics"
            monitor = Thread(target=sample_native_apps, args=(diagnostics, stop), daemon=True)
            monitor.start()
        try:
            subprocess.run([str(x) for x in command], cwd=directory, check=True)
        finally:
            stop.set()
            if monitor is not None:
                monitor.join()

    if args.lane in ("native", "device") and args.model_path is not None:
        if not args.model_path.is_file():
            parser.error("--model-path must exist on this host; use --model-url for remote devices")
    if args.lane == "native" and args.model_path is None:
        parser.error("native requires --model-path; no silently skipped smoke tests")
    if args.lane in ("web", "device") and not (args.model_url or args.model_path):
        parser.error("this lane requires an explicit model fixture")
    if args.lane == "web" and not args.model_url:
        parser.error("web requires --model-url")
    if args.lane == "build" and not args.platform:
        parser.error("build requires --platform")
    if args.lane == "device" and not args.device:
        parser.error("device requires --device")

    if args.native_diagnostics and (sys.platform != "darwin" or args.lane not in ("native", "device")):
        parser.error("--native-diagnostics requires an Apple native/device runtime lane")
    if args.core_path is not None:
        if args.lane != "package":
            parser.error("--core-path is only supported by the package preparation lane")
        core_pubspec = args.core_path.resolve() / "pubspec.yaml"
        if not core_pubspec.is_file():
            parser.error("--core-path must contain a core pubspec.yaml")
        core_text = core_pubspec.read_text()
        name = re.search(r"^name:\s*([^\s#]+)", core_text, re.MULTILINE)
        version = re.search(r"^version:\s*([^\s#]+)", core_text, re.MULTILINE)
        pin = re.search(r"^  flutter_edge_ai:\s*([^\s#]+)", (PACKAGE / "pubspec.yaml").read_text(), re.MULTILINE)
        if not name or name.group(1) != "flutter_edge_ai" or not version or not pin or version.group(1) != pin.group(1):
            parser.error("--core-path must be flutter_edge_ai at the connector's exact dependency version")

    version = json.loads(subprocess.check_output([flutter, "--version", "--machine"], text=True))
    expected = (PACKAGE / ".flutter-version").read_text().strip()
    if version["frameworkVersion"] != expected:
        parser.error(f"Use the pinned Flutter SDK {expected}")
    if args.lane != "package":
        run([flutter, "pub", "get"])
    if args.lane == "contracts":
        run([flutter, "pub", "get"], PACKAGE / "example")
        run([dart, "format", "--output=none", "--set-exit-if-changed", "lib", "test", "example/lib", "example/test", "example/integration_test"])
        run([flutter, "analyze"])
        run([sys.executable, "-m", "unittest", "discover", "-s", "test", "-p", "test_tooling.py"])
        run([flutter, "test", "test/connector_test.dart"])
        run([flutter, "test", "test/connector_test.dart", "test/web_smoke_test.dart", "--platform", "chrome"])
        run([flutter, "test"], PACKAGE / "example")
    elif args.lane == "native":
        fixture = f"--dart-define=GGUF_MODEL_PATH={args.model_path.resolve()}"
        if sys.platform in ("win32", "darwin"):
            # Qualify the application's framework/DLL layout on Apple/Windows.
            # VM-host behavior is not a substitute for the packaged runtime.
            platform = "windows" if sys.platform == "win32" else "macos"
            print(f"{platform} CPU smoke uses the packaged desktop host.", flush=True)
            run([flutter, "pub", "get"], PACKAGE / "example")
            if platform == "macos":
                # A CLI path has no file-picker grant in the sandboxed app.
                # Download the verified fixture into app-owned storage instead.
                server = create_server(args.model_path.resolve())
                thread = Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    fixture = f"--dart-define=GGUF_MODEL_URL=http://127.0.0.1:{server.server_address[1]}/chat.gguf"
                    run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", platform, fixture], PACKAGE / "example")
                finally:
                    server.shutdown()
                    thread.join()
                    server.server_close()
            else:
                run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", platform, fixture], PACKAGE / "example")
        else:
            run([flutter, "test", "test/native_smoke_test.dart", fixture])
    elif args.lane == "web":
        run([sys.executable, "tool/fetch_web_assets.py"])
        command = [sys.executable, "tool/run_web_smoke.py", "--flutter", flutter, "--model-url", args.model_url]
        if args.storage_helper_url:
            command += ["--storage-helper-url", args.storage_helper_url]
        run(command)
    elif args.lane == "package":
        # The adapter uses pinned core implementation APIs. Keep exact bounds
        # until public extension APIs replace the shims. Publication/versioning
        # remains separate; this validates the source archive only.
        # An enclosing repository's .pubignore can hide this entire package.
        # Validate the standalone artifact without inheriting that root rule.
        with tempfile.TemporaryDirectory(prefix="edge-llama-publish-") as directory:
            staged = Path(directory) / PACKAGE.name
            shutil.copytree(PACKAGE, staged, ignore=shutil.ignore_patterns(
                ".git", ".dart_tool", "build", "coverage", "__pycache__",
                "*.pyc", "*.log", "fixtures", "webgpu_bridge", ".gradle",
                "Pods", "ephemeral", ".symlinks", "pubspec_overrides.yaml"))
            # A published adapter must resolve without its development workspace.
            pubspec = staged / "pubspec.yaml"
            pubspec.write_text(re.sub(r"^resolution: workspace\r?\n", "", pubspec.read_text(), flags=re.MULTILINE))
            if args.core_path is not None:
                # Keep the original hosted constraint in the archive. The
                # temporary override is excluded by .pubignore and never ships.
                staged_core = Path(directory) / "core"
                shutil.copytree(args.core_path.resolve(), staged_core,
                                ignore=shutil.ignore_patterns(".git", ".dart_tool", "build", "coverage", "example", "test", "__pycache__", "pubspec_overrides.yaml"))
                core_pubspec = staged_core / "pubspec.yaml"
                core_pubspec.write_text(re.sub(r"^resolution: workspace\r?\n", "", core_pubspec.read_text(), flags=re.MULTILINE))
                override = "dependency_overrides:\n  flutter_edge_ai:\n    path: " + json.dumps(str(staged_core)) + "\n"
                (staged / "pubspec_overrides.yaml").write_text(override)
                if (staged / "example/pubspec.yaml").is_file():
                    (staged / "example/pubspec_overrides.yaml").write_text(override)
                print("PACKAGE PREPARATION: using the matching local core. This does not validate hosted consumer resolution.", flush=True)
            run([flutter, "pub", "get"], staged)
            result = subprocess.run([flutter, "pub", "publish", "--dry-run", "--ignore-warnings"], cwd=staged, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, flush=True)
        result.check_returncode()
        allowed = ('Your dependency on "flutter_edge_ai" should allow more than one version.',
                   'Your dependency on "llamadart" should allow more than one version.',
                   "doesn't mention current version")
        if args.core_path is not None:
            allowed += ("Non-dev dependencies are overridden in pubspec_overrides.yaml.",)
        warnings = [block for block in result.stdout.split("\n* ")[1:]]
        if any(not any(message in block for message in allowed) for block in warnings):
            raise RuntimeError("Unexpected publish-validation warning")
    elif args.lane == "device":
        fixture = (f"--dart-define=GGUF_MODEL_PATH={args.model_path.resolve()}" if args.model_path
                   else f"--dart-define=GGUF_MODEL_URL={args.model_url}")
        run([flutter, "pub", "get"], PACKAGE / "example")
        run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", args.device, fixture], PACKAGE / "example")
    elif args.lane == "build":
        run([flutter, "pub", "get"], PACKAGE / "example")
        target = "apk" if args.platform == "android" else args.platform
        command = [flutter, "build", target, "--release"]
        if args.platform == "android":
            command += ["--target-platform", "android-arm64"]
        elif args.platform == "ios":
            command += ["--no-codesign"]
        elif args.platform == "web":
            run([sys.executable, "tool/fetch_web_assets.py"])
            command += ["--wasm"]
        run(command, PACKAGE / "example")
        if args.platform == "web":
            run([sys.executable, "tool/validate_web_build.py"])


if __name__ == "__main__":
    main()
