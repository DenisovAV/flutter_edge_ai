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
from smoke_result import require_smoke_success

PACKAGE = Path(__file__).resolve().parents[1]


def sample_native_apps(directory, stop, simulator_device=None):
    """Retain recent Apple thread samples and the test simulator screen."""
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
                if simulator_device is not None and slot == 0:
                    subprocess.run(["xcrun", "simctl", "io", simulator_device, "screenshot",
                                    str(directory / "simulator.png")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                subprocess.run(["sample", pid, "1", "-file", str(directory / f"app-{pid}-{slot}.txt")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            # Diagnostics must not turn a failed runtime test into a success or
            # replace its failure with a sampler/tool availability failure.
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=("contracts", "native", "web", "package", "build", "device", "capabilities"))
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--model-url")
    parser.add_argument("--storage-helper-url")
    parser.add_argument("--platform", choices=("android", "ios", "macos", "windows", "linux", "web"))
    parser.add_argument("--device")
    parser.add_argument("--cpu-threads", type=int,
                        help="Packaged runtime smoke: explicit CPU generation/batch thread budget")
    parser.add_argument("--native-diagnostics", action="store_true",
                        help="Apple runtime lanes: retain recent app thread samples in RUNNER_TEMP")
    parser.add_argument("--capability", choices=("tools", "audio", "vision", "lora", "gpu"))
    parser.add_argument("--projector-path", type=Path)
    parser.add_argument("--input-path", type=Path)
    parser.add_argument("--adapter-path", type=Path)
    args = parser.parse_args()
    # Resolve PATHEXT on Windows so CreateProcess receives flutter.bat.
    flutter = shutil.which(args.flutter) or args.flutter
    sdk = Path(flutter).parent / ("dart.bat" if os.name == "nt" else "dart")
    dart = str(sdk) if sdk.exists() else "dart"

    def run(command, directory=PACKAGE, smoke=None):
        print("Running:", subprocess.list2cmdline([str(x) for x in command]), flush=True)
        stop = Event()
        monitor = None
        if args.native_diagnostics and len(command) > 1 and command[1] == "test":
            diagnostics = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "edge-ai-native-diagnostics"
            simulator = args.device if args.lane == "device" and args.device != "macos" else None
            monitor = Thread(target=sample_native_apps, args=(diagnostics, stop, simulator), daemon=True)
            monitor.start()
        try:
            result = subprocess.run([str(x) for x in command], cwd=directory, check=not smoke,
                                    **({"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT, "text": True} if smoke else {}))
            if smoke:
                print(result.stdout, flush=True)
                result.check_returncode()
                require_smoke_success(result.stdout, smoke)
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

    if args.cpu_threads is not None and (args.cpu_threads < 1 or
            not (args.lane == "device" or args.lane == "native" and sys.platform in ("win32", "darwin"))):
        parser.error("--cpu-threads requires a positive budget and a packaged native/device smoke")
    thread_defines = ([] if args.cpu_threads is None else
                      [f"--dart-define=GGUF_CPU_THREADS={args.cpu_threads}"])

    if args.native_diagnostics and (sys.platform != "darwin" or args.lane not in ("native", "device")):
        parser.error("--native-diagnostics requires an Apple native/device runtime lane")
    if args.lane == "capabilities":
        required = [args.model_path]
        if args.capability in ("audio", "vision"):
            required += [args.projector_path, args.input_path]
        if args.capability == "lora": required += [args.adapter_path]
        if args.capability is None or any(path is None or not path.is_file() for path in required):
            parser.error("capabilities requires --capability and existing model/projector/input/adapter fixtures for that feature")

    version = json.loads(subprocess.check_output([flutter, "--version", "--machine"], text=True))
    expected = (PACKAGE / ".flutter-version").read_text().strip()
    if version["frameworkVersion"] not in ("3.47.0", expected):
        parser.error(f"Use workspace Flutter 3.47.0 or CI Flutter {expected}")
    if args.lane != "package":
        run([flutter, "pub", "get"])
    if args.lane == "contracts":
        run([flutter, "pub", "get"], PACKAGE / "example")
        run([dart, "format", "--output=none", "--set-exit-if-changed", "lib", "test", "example/lib", "example/test", "example/integration_test"])
        run([flutter, "analyze"])
        run([sys.executable, "-m", "unittest", "discover", "-s", "test", "-p", "test_tooling.py"])
        run([flutter, "test", "test/connector_test.dart", "test/native_identity_test.dart"])
        run([flutter, "test", "test/connector_test.dart", "test/web_smoke_test.dart", "test/web_location_test.dart", "--platform", "chrome"])
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
                    run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", platform, fixture, *thread_defines, "--reporter", "json"], PACKAGE / "example", smoke="packaged native runtime installs")
                finally:
                    server.shutdown()
                    thread.join()
                    server.server_close()
            else:
                run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", platform, fixture, *thread_defines, "--reporter", "json"], PACKAGE / "example", smoke="packaged native runtime installs")
        else:
            run([flutter, "test", "test/native_smoke_test.dart", fixture, "--reporter", "json"], smoke="published facade installs GGUF")
    elif args.lane == "web":
        run([sys.executable, "tool/fetch_web_assets.py"])
        command = [sys.executable, "tool/run_web_smoke.py", "--flutter", flutter, "--model-url", args.model_url]
        if args.storage_helper_url:
            command += ["--storage-helper-url", args.storage_helper_url]
        run(command)
    elif args.lane == "package":
        # Validate the standalone archive and hosted consumer resolution.
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
        warnings = [block for block in result.stdout.split("\n* ")[1:]]
        if warnings:
            raise RuntimeError("Unexpected publish-validation warning")
    elif args.lane == "device":
        fixture = (f"--dart-define=GGUF_MODEL_PATH={args.model_path.resolve()}" if args.model_path
                   else f"--dart-define=GGUF_MODEL_URL={args.model_url}")
        run([flutter, "pub", "get"], PACKAGE / "example")
        run([flutter, "test", "integration_test/connector_smoke_test.dart", "-d", args.device, fixture, *thread_defines, "--reporter", "json"], PACKAGE / "example", smoke="packaged native runtime installs")
    elif args.lane == "capabilities":
        labels = {"tools": "native typed thinking", "audio": "native audio projector", "vision": "native vision projector", "lora": "native LoRA session", "gpu": "explicit GPU loads"}
        prefix = "TOOL" if args.capability == "tools" else args.capability.upper()
        defines = [f"--dart-define=GGUF_{prefix}_MODEL_PATH={args.model_path.resolve()}"]
        if args.projector_path: defines.append(f"--dart-define=GGUF_{prefix}_PROJECTOR_PATH={args.projector_path.resolve()}")
        if args.input_path: defines.append(f"--dart-define=GGUF_{prefix}_FILE_PATH={args.input_path.resolve()}")
        if args.adapter_path: defines.append(f"--dart-define=GGUF_LORA_ADAPTER_PATH={args.adapter_path.resolve()}")
        run([flutter, "test", "test/native_capabilities_test.dart", "--plain-name", labels[args.capability], "--reporter", "json", *defines], smoke=labels[args.capability])
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
