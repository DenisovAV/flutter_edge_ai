import contextlib
import io
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tool"))
import fetch_test_model
import fetch_web_assets
import validate_web_build
import verify as package_verify
from smoke_result import require_smoke_success


REAL_RUN_SMOKE = package_verify.run_smoke


class ToolingTests(unittest.TestCase):
    def setUp(self):
        # CLI-routing fixtures below mock subprocess.run. Streaming/process
        # behavior is exercised separately through the real helper.
        def smoke(command, directory, expected, timeout=None):
            result = package_verify.subprocess.run(command, cwd=directory, check=False,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, flush=True)
            result.check_returncode()
            require_smoke_success(result.stdout, expected)
        mocked = patch.object(package_verify, "run_smoke", side_effect=smoke)
        mocked.start()
        self.addCleanup(mocked.stop)

    def test_smoke_gate_rejects_missing_skipped_and_failed_model_execution(self):
        start = {"type": "testStart", "test": {"id": 7, "name": "required model"}}
        for done in [None, {"type": "testDone", "testID": 7, "result": "success", "skipped": True}, {"type": "testDone", "testID": 7, "result": "failure"}]:
            events = [start, {"type": "done", "success": True}]
            if done is not None: events.append(done)
            with self.assertRaisesRegex(RuntimeError, "did not execute"):
                require_smoke_success("\n".join(json.dumps(e) for e in events), "required model")
        events = [start, {"type": "testDone", "testID": 7, "result": "success", "skipped": False}, {"type": "done", "success": True}]
        require_smoke_success("\n".join(json.dumps(e) for e in events), "required model")

    def test_windows_native_lane_uses_packaged_host_for_real_dll_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "chat.gguf"
            model.write_bytes(b"fixture")
            with patch.object(sys, "argv", ["verify.py", "native", "--model-path", str(model)]), \
                 patch.object(sys, "platform", "win32"), \
                 patch.object(package_verify.shutil, "which", return_value="flutter"), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True}))) as run:
                package_verify.main()
            command = run.call_args_list[-1].args[0]
            self.assertIn("integration_test/connector_smoke_test.dart", command)
            self.assertIn("windows", command)
            self.assertIn(f"--dart-define=GGUF_MODEL_PATH={model.resolve()}", command)
            self.assertEqual(run.call_args_list[-1].kwargs["cwd"], package_verify.PACKAGE / "example")

    def test_macos_native_lane_uses_verified_network_fixture_and_closes_server(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "chat.gguf"
            model.write_bytes(b"fixture")
            server = MagicMock(server_address=("127.0.0.1", 8099))
            with patch.object(sys, "argv", ["verify.py", "native", "--model-path", str(model)]), \
                 patch.object(sys, "platform", "darwin"), \
                 patch.object(package_verify, "create_server", return_value=server) as create_server, \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True}))) as run:
                package_verify.main()
            command = run.call_args_list[-1].args[0]
            self.assertIn("integration_test/connector_smoke_test.dart", command)
            self.assertIn("macos", command)
            self.assertIn("--dart-define=GGUF_MODEL_URL=http://127.0.0.1:8099/chat.gguf", command)
            self.assertNotIn(f"--dart-define=GGUF_MODEL_PATH={model.resolve()}", command)
            self.assertEqual(run.call_args_list[-1].kwargs["cwd"], package_verify.PACKAGE / "example")
            create_server.assert_called_once_with(model.resolve())
            server.shutdown.assert_called_once()
            server.server_close.assert_called_once()

    def test_macos_fixture_server_closes_when_the_runtime_smoke_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "chat.gguf"
            model.write_bytes(b"fixture")
            server = MagicMock(server_address=("127.0.0.1", 8099))
            failure = subprocess.CalledProcessError(1, ["flutter", "test"])
            with patch.object(sys, "argv", ["verify.py", "native", "--model-path", str(model)]), \
                 patch.object(sys, "platform", "darwin"), \
                 patch.object(package_verify, "create_server", return_value=server), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", side_effect=[
                     subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                     subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                     failure,
                 ]):
                with self.assertRaises(subprocess.CalledProcessError):
                    package_verify.main()
            server.shutdown.assert_called_once()
            server.server_close.assert_called_once()

    def test_packaged_cpu_budget_is_passed_to_the_real_device_smoke(self):
        with patch.object(sys, "argv", ["verify.py", "device", "--device", "emulator-5554", "--model-url", "https://example.test/model.gguf", "--cpu-threads", "1"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True}))) as run:
            package_verify.main()
        command = run.call_args_list[-1].args[0]
        self.assertIn("integration_test/connector_smoke_test.dart", command)
        self.assertIn("--dart-define=GGUF_CPU_THREADS=1", command)

    def test_failed_device_smoke_preserves_output_and_remains_failed(self):
        output = io.StringIO()
        with patch.object(sys, "argv", ["verify.py", "device", "--device", "ios", "--model-url", "https://example.test/model.gguf"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0),
                 subprocess.CompletedProcess([], 0),
                 subprocess.CompletedProcess(["flutter", "test"], 1, stdout="runtime smoke failed before completion"),
             ]), contextlib.redirect_stdout(output):
            with self.assertRaises(subprocess.CalledProcessError):
                package_verify.main()
        self.assertIn("runtime smoke failed before completion", output.getvalue())

    def test_invalid_cpu_budgets_fail_before_flutter(self):
        for arguments in (["device", "--device", "ios", "--model-url", "https://example.test/model.gguf", "--cpu-threads", "0"],
                          ["contracts", "--cpu-threads", "1"]):
            with patch.object(sys, "argv", ["verify.py", *arguments]), \
                 patch.object(package_verify.subprocess, "check_output") as flutter:
                with self.assertRaises(SystemExit) as error:
                    package_verify.main()
                self.assertEqual(error.exception.code, 2)
                flutter.assert_not_called()

    def test_native_sampler_targets_only_test_apps_and_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            stop = MagicMock()
            stop.wait.side_effect = [False, True]
            processes = subprocess.CompletedProcess([], 0, stdout=(
                "123 /Applications/Unrelated.app/Contents/MacOS/Unrelated\n"
                "456 /tmp/flutter_edge_ai_llama_demo.app/Contents/MacOS/flutter_edge_ai_llama_demo\n"
                "789 /tmp/Runner.app/Runner\n"))
            with patch.object(package_verify.subprocess, "run", side_effect=[
                processes, subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})), subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
            ]) as run:
                package_verify.sample_native_apps(Path(directory), stop)
            samples = [call.args[0] for call in run.call_args_list if call.args[0][0] == "sample"]
            self.assertEqual([command[1] for command in samples], ["456", "789"])

    def test_apple_device_diagnostics_preserve_the_simulator_screen(self):
        with tempfile.TemporaryDirectory() as directory:
            stop = MagicMock()
            stop.wait.side_effect = [False, True]
            processes = subprocess.CompletedProcess([], 0, stdout="789 /tmp/Runner.app/Runner\n")
            with patch.object(package_verify.subprocess, "run", side_effect=[
                processes, subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})), subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
            ]) as run:
                package_verify.sample_native_apps(Path(directory), stop, "test-simulator")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn(["xcrun", "simctl", "io", "test-simulator", "screenshot",
                           str(Path(directory) / "simulator.png")], commands)

    def test_fixture_server_rejects_unverified_model(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "chat.gguf"
            model.write_bytes(b"invalid fixture")
            with self.assertRaisesRegex(ValueError, "pinned size and checksum"):
                package_verify.create_server(model)

    def test_publish_preserves_metadata_outside_enclosing_ignore_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "connector"
            package.mkdir()
            (root / ".pubignore").write_text("/connector/\n")
            for name in ("pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md"):
                (package / name).write_text("source metadata")
            (package / ".flutter-version").write_text("3.47.1")
            (package / ".dart_tool").mkdir()
            (package / ".dart_tool/cache").write_text("local cache")
            (package / "tool/fixtures").mkdir(parents=True)
            (package / "tool/fixtures/chat.gguf").write_bytes(b"local model")
            checked = []

            def invoke(command, **kwargs):
                if "publish" in command:
                    staged = Path(kwargs["cwd"])
                    self.assertFalse(staged.is_relative_to(root))
                    for name in ("pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md"):
                        self.assertEqual((staged / name).read_text(), "source metadata")
                    self.assertFalse((staged / ".dart_tool").exists())
                    self.assertFalse((staged / "tool/fixtures").exists())
                    checked.append(staged)
                return subprocess.CompletedProcess(command, 0, stdout="Validating package...\n")

            with patch.object(package_verify, "PACKAGE", package), \
                 patch.object(sys, "argv", ["verify.py", "package"]), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", side_effect=invoke):
                package_verify.main()
            self.assertEqual(len(checked), 1)
            self.assertFalse(checked[0].exists())

    def test_publish_checks_hosted_resolution_without_development_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "connector"
            package.mkdir()
            source = "name: connector\nresolution: workspace\ndependencies:\n  flutter_edge_ai: 2.2.0\n"
            (package / "pubspec.yaml").write_text(source)
            (package / ".flutter-version").write_text("3.47.1")
            (package / "example").mkdir()
            (package / "example/pubspec_overrides.yaml").write_text("dependency_overrides: {}\n")
            checked = []

            def invoke(command, **kwargs):
                staged = Path(kwargs["cwd"])
                self.assertFalse((staged / "example/pubspec_overrides.yaml").exists())
                self.assertFalse((staged / "pubspec_overrides.yaml").exists())
                pubspec = (staged / "pubspec.yaml").read_text()
                self.assertNotIn("resolution: workspace", pubspec)
                self.assertIn("flutter_edge_ai: 2.2.0", pubspec)
                checked.append(command)
                return subprocess.CompletedProcess(command, 0, stdout="Validating package...\n")

            with patch.object(package_verify, "PACKAGE", package), \
                 patch.object(sys, "argv", ["verify.py", "package"]), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", side_effect=invoke):
                package_verify.main()
            self.assertEqual(len(checked), 2)
            self.assertEqual((package / "pubspec.yaml").read_text(), source)

    def test_sdk_command_uses_resolved_executable_for_windows_path_search(self):
        flutter = r"C:\flutter\bin\flutter.bat"
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify.shutil, "which", return_value=flutter), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}') as version, \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                 subprocess.CompletedProcess([], 0, stdout="Validating package...\n"),
             ]) as run:
            package_verify.main()
        version.assert_called_once_with([flutter, "--version", "--machine"], text=True)
        self.assertEqual(run.call_args_list[0].args[0], [flutter, "pub", "get"])



    def test_publish_gate_rejects_exact_dependency_warning(self):
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                 subprocess.CompletedProcess([], 0, stdout='Validating package...\n* Your dependency on "flutter_edge_ai" should allow more than one version.\n'),
             ]):
            with self.assertRaisesRegex(RuntimeError, "Unexpected publish-validation"):
                package_verify.main()


    def test_obsolete_local_core_option_is_rejected_before_flutter(self):
        with patch.object(sys, "argv", ["verify.py", "package", "--core-path", "/unused"]), \
             patch.object(package_verify.subprocess, "check_output") as flutter:
            with self.assertRaises(SystemExit) as error:
                package_verify.main()
            self.assertEqual(error.exception.code, 2)
            flutter.assert_not_called()

    def test_workspace_sdk_can_run_hosted_package_gate(self):
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.0"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, stdout=""),
                 subprocess.CompletedProcess([], 0, stdout="Validating package...\n"),
             ]) as run:
            package_verify.main()
        self.assertEqual(run.call_count, 2)

    def test_other_sdk_versions_are_rejected_before_checks(self):
        for sdk in ["3.44.0", "3.46.0", "3.48.0"]:
            with self.subTest(sdk=sdk), \
                 patch.object(sys, "argv", ["verify.py", "contracts"]), \
                 patch.object(package_verify.subprocess, "check_output", return_value=json.dumps({"frameworkVersion": sdk})), \
                 patch.object(package_verify.subprocess, "run") as run:
                with self.assertRaises(SystemExit) as error:
                    package_verify.main()
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_hosted_package_gate_rejects_a_development_override_hint(self):
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                 subprocess.CompletedProcess([], 0, stdout="Validating package...\n* Non-dev dependencies are overridden in pubspec_overrides.yaml.\n"),
             ]):
            with self.assertRaisesRegex(RuntimeError, "Unexpected publish-validation"):
                package_verify.main()

    def test_hosted_resolution_failure_is_not_retried_with_local_core(self):
        failure = subprocess.CalledProcessError(1, ["flutter", "pub", "get"])
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=failure) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                package_verify.main()
        self.assertEqual(run.call_count, 1)

    def test_required_smokes_reject_missing_fixtures_before_invoking_flutter(self):
        tool = Path(__file__).resolve().parents[1] / "tool/verify.py"
        for arguments in (["native"], ["web"], ["device", "--model-url", "https://example.test/model.gguf"]):
            result = subprocess.run([sys.executable, str(tool), *arguments, "--flutter", "/nonexistent/flutter"], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_publish_gate_rejects_unexpected_warnings(self):
        with patch.object(sys, "argv", ["verify.py", "package", "--flutter", "flutter"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, stdout=json.dumps({"type":"testStart","test":{"id":1,"name":"packaged native runtime installs"}}) + "\n" + json.dumps({"type":"testDone","testID":1,"result":"success","skipped":False,"hidden":False}) + "\n" + json.dumps({"type":"done","success":True})),
                 subprocess.CompletedProcess([], 0, stdout="Validating package...\n* Unexpected warning\n"),
             ]):
            with self.assertRaisesRegex(RuntimeError, "Unexpected publish-validation"):
                package_verify.main()

    def test_fixture_corruption_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.gguf"
            path.write_bytes(b"GGUF-original")
            spec = {"size_bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            self.assertTrue(fetch_test_model.verify(path, spec))
            path.write_bytes(b"GGUF-modified")
            self.assertFalse(fetch_test_model.verify(path, spec))

    def test_wrong_manifest_does_not_download_or_replace_runtime_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "runtime"
            output.mkdir()
            sentinel = output / "llama_webgpu_bridge.js"
            sentinel.write_bytes(b"existing runtime")
            downloaded = []
            def download(name, target):
                downloaded.append(name)
                target.write_bytes(b'{"bridge_assets_tag":"v0.1.54"}')
            with patch.object(fetch_web_assets, "download", download), patch.object(fetch_web_assets, "OUT", output):
                with self.assertRaisesRegex(RuntimeError, "manifest checksum"):
                    fetch_web_assets.main([])
            self.assertEqual(downloaded, ["manifest.json"])
            self.assertEqual(sentinel.read_bytes(), b"existing runtime")

    def test_custom_headers_preserve_isolation_and_reject_conflicting_routes(self):
        headers = "/*\n  Cross-Origin-Opener-Policy: same-origin\n  Cross-Origin-Embedder-Policy: require-corp\n  X-Content-Type-Options: nosniff\n/assets/*\n  Cache-Control: public, max-age=86400\n"
        validate_web_build.validate_headers(headers)
        for changed in [headers.replace("require-corp", "unsafe-none"),
                        headers.replace("/*\n", "/app/*\n", 1),
                        headers + "/worker.js\n  Cross-Origin-Opener-Policy: unsafe-none\n",
                        headers + "/worker.js\n  ! Cross-Origin-Embedder-Policy\n"]:
            with self.assertRaisesRegex(RuntimeError, "isolation|COOP"):
                validate_web_build.validate_headers(changed)

    def test_consumer_additions_keep_runtime_hash_and_helper_interface_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "webgpu_bridge"
            runtime.mkdir()
            asset = b"pinned runtime"
            (runtime / "runtime.js").write_bytes(asset)
            manifest = json.dumps({"artifacts": {"runtime.js": {"size_bytes": len(asset), "sha256": hashlib.sha256(asset).hexdigest()}}}).encode()
            (runtime / "manifest.json").write_bytes(manifest)
            for filename in ["flutter_bootstrap.js", "main.dart.wasm"]:
                (root / filename).write_text("fixture")
            web = validate_web_build.PACKAGE / "example/web"
            (root / "index.html").write_text((web / "index.html").read_text())
            helper = (web / "cache_api.js").read_text() + "\nwindow.consumerExtra = true;\n"
            (root / "cache_api.js").write_text(helper)
            (root / "cache_api.LICENSE").write_bytes((web / "cache_api.LICENSE").read_bytes())
            (root / "_headers").write_text((web / "_headers").read_text() + "  X-Content-Type-Options: nosniff\n")
            with patch.object(validate_web_build, "FILES", ("runtime.js",)), \
                 patch.object(validate_web_build, "MANIFEST_SHA256", hashlib.sha256(manifest).hexdigest()):
                validate_web_build.validate(root)
                (root / "cache_api.js").write_text(helper.replace("window.cacheHas", "window.missingCacheHas"))
                with self.assertRaisesRegex(RuntimeError, "missing cacheHas"):
                    validate_web_build.validate(root)
                (root / "cache_api.js").write_text(helper)
                (runtime / "runtime.js").write_bytes(b"changed runtime")
                with self.assertRaisesRegex(RuntimeError, "corrupt runtime"):
                    validate_web_build.validate(root)

    def test_javascript_checks_actual_exports_and_bootstrap_asset_selection(self):
        web = validate_web_build.PACKAGE / "example/web"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            html = (web / "index.html").read_text()
            helper = (web / "cache_api.js").read_text()
            (root / "index.html").write_text(html)
            (root / "cache_api.js").write_text(helper)
            validate_web_build.validate_javascript(root)
            (root / "cache_api.js").write_text("\n".join("// " + line for line in helper.splitlines()))
            with self.assertRaisesRegex(RuntimeError, "missing cacheHas"):
                validate_web_build.validate_javascript(root)
            (root / "cache_api.js").write_text(helper)
            for changed in [html.replace("webgpu_bridge/", "https://cdn.example/"),
                            html.replace('href="$FLUTTER_BASE_HREF"', 'href="https://cdn.example/"'),
                            html.replace("root + 'llama_webgpu_core.wasm'", "'https://cdn.example/core.wasm'"),
                            html.replace("type=\"module\"", "type=\"text/plain\"")]:
                (root / "index.html").write_text(changed)
                with self.assertRaisesRegex(RuntimeError, "local pinned"):
                    validate_web_build.validate_javascript(root)

    def test_smoke_streams_before_exit_and_requires_completed_execution(self):
        report = [
            {"type":"testStart","test":{"id":1,"name":"required model"}},
            {"type":"testDone","testID":1,"result":"success","skipped":False},
            {"type":"done","success":True},
        ]
        with tempfile.TemporaryDirectory() as directory:
            ack = Path(directory) / "ack"
            class Output(io.StringIO):
                def write(self, data):
                    if 'testStart' in data: ack.write_text("streamed before exit")
                    return super().write(data)
            script = ("from pathlib import Path;import time;print(" + repr(json.dumps(report[0])) + ",flush=True)\n"
                      "while not Path(" + repr(str(ack)) + ").exists(): time.sleep(0.01)\n"
                      "print(" + repr("\n".join(json.dumps(x) for x in report[1:])) + ",flush=True)")
            with contextlib.redirect_stdout(Output()):
                REAL_RUN_SMOKE([sys.executable, "-c", script], Path.cwd(), "required model", timeout=10)
            self.assertTrue(ack.exists())
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "did not execute"):
            REAL_RUN_SMOKE([sys.executable, "-c", "print('{\"type\":\"done\",\"success\":true}')"], Path.cwd(), "required model", timeout=5)

    def test_smoke_timeout_retains_live_startup_output(self):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired) as failure:
            REAL_RUN_SMOKE([sys.executable, "-c", "import time;print('waiting for debug connection',flush=True);time.sleep(30)"], Path.cwd(), "required model", timeout=5)
        self.assertIn("waiting for debug connection", failure.exception.output)

    def test_simulator_startup_retry_is_bounded_and_preserves_failures(self):
        arguments = ["verify.py", "device", "--device", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "--model-url", "https://example.test/chat.gguf", "--simulator-retry"]
        timeout = subprocess.TimeoutExpired(["flutter"], 600, output="loading test")
        with patch.object(sys, "argv", arguments), patch.object(sys, "platform", "darwin"), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(package_verify, "run_smoke", side_effect=[timeout, None]) as smoke:
            package_verify.main()
        self.assertEqual(smoke.call_count, 2)
        self.assertEqual([call.kwargs["timeout"] for call in smoke.call_args_list], [600, 600])
        controls = [call.args[0][2] for call in run.call_args_list if call.args[0][:2] == ["xcrun", "simctl"]]
        self.assertEqual(controls, ["shutdown", "boot", "bootstatus"])
        failures = [subprocess.CalledProcessError(1, ["flutter"], output="assertion failed"),
                    subprocess.TimeoutExpired(["flutter"], 600, output='{"type":"testStart","test":{"name":"packaged native runtime installs"}}')]
        for error in failures:
            with patch.object(sys, "argv", arguments), patch.object(sys, "platform", "darwin"), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                 patch.object(package_verify, "run_smoke", side_effect=error) as smoke:
                with self.assertRaises(type(error)): package_verify.main()
                self.assertEqual(smoke.call_count, 1)

    def test_workspace_sdk_acceptance_follows_fvm_instead_of_a_literal(self):
        with patch.object(sys, "argv", ["verify.py", "package"]), \
             patch.object(package_verify, "workspace_flutter", return_value="3.48.4"), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.48.4"}'), \
             patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="Validating package...")):
            package_verify.main()

    def test_release_build_rejects_missing_or_corrupt_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                validate_web_build.validate(root)
            runtime = root / "webgpu_bridge"
            runtime.mkdir()
            (runtime / "manifest.json").write_text("{}")
            with self.assertRaisesRegex(RuntimeError, "wrong Web runtime manifest"):
                validate_web_build.validate(root)


if __name__ == "__main__":
    unittest.main()
