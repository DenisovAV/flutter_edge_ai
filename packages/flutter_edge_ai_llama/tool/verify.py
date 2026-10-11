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

PACKAGE = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=("contracts", "native", "web", "package", "build", "device"))
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--model-url")
    parser.add_argument("--storage-helper-url")
    parser.add_argument("--platform", choices=("android", "ios", "macos", "windows", "linux", "web"))
    parser.add_argument("--device")
    args = parser.parse_args()
    # Resolve PATHEXT on Windows so CreateProcess receives flutter.bat.
    flutter = shutil.which(args.flutter) or args.flutter
    sdk = Path(flutter).parent / ("dart.bat" if os.name == "nt" else "dart")
    dart = str(sdk) if sdk.exists() else "dart"

    def run(command, directory=PACKAGE):
        print("Running:", subprocess.list2cmdline([str(x) for x in command]), flush=True)
        subprocess.run([str(x) for x in command], cwd=directory, check=True)

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
        if sys.platform == "win32":
            # Flutter's Windows VM host cannot reliably discover/use the split
            # native modules. Exercise the actual app's DLL layout instead.
            print("Windows CPU smoke uses the packaged desktop host.", flush=True)
            run([flutter, "pub", "get"], PACKAGE / "example")
            run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", "windows", fixture], PACKAGE / "example")
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
            run([flutter, "pub", "get"], staged)
            result = subprocess.run([flutter, "pub", "publish", "--dry-run", "--ignore-warnings"], cwd=staged, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, flush=True)
        result.check_returncode()
        allowed = ('Your dependency on "flutter_edge_ai" should allow more than one version.',
                   'Your dependency on "llamadart" should allow more than one version.',
                   "doesn't mention current version")
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
