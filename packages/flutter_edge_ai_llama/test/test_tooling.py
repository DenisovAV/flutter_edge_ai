import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tool"))
import fetch_test_model
import fetch_web_assets
import validate_web_build
import verify as package_verify


class ToolingTests(unittest.TestCase):
    def test_windows_native_lane_uses_packaged_host_for_real_dll_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "chat.gguf"
            model.write_bytes(b"fixture")
            with patch.object(sys, "argv", ["verify.py", "native", "--model-path", str(model)]), \
                 patch.object(sys, "platform", "win32"), \
                 patch.object(package_verify.shutil, "which", return_value="flutter"), \
                 patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
                 patch.object(package_verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                package_verify.main()
            command = run.call_args_list[-1].args[0]
            self.assertIn("integration_test/connector_smoke_test.dart", command)
            self.assertIn("windows", command)
            self.assertIn(f"--dart-define=GGUF_MODEL_PATH={model.resolve()}", command)
            self.assertEqual(run.call_args_list[-1].kwargs["cwd"], package_verify.PACKAGE / "example")

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
            source = "name: connector\nresolution: workspace\ndependencies:\n  flutter_edge_ai: 2.1.3\n"
            (package / "pubspec.yaml").write_text(source)
            (package / ".flutter-version").write_text("3.47.1")
            (package / "example").mkdir()
            (package / "example/pubspec_overrides.yaml").write_text("dependency_overrides: {}\n")
            checked = []

            def invoke(command, **kwargs):
                staged = Path(kwargs["cwd"])
                self.assertFalse((staged / "example/pubspec_overrides.yaml").exists())
                pubspec = (staged / "pubspec.yaml").read_text()
                self.assertNotIn("resolution: workspace", pubspec)
                self.assertIn("flutter_edge_ai: 2.1.3", pubspec)
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
                 subprocess.CompletedProcess([], 0),
                 subprocess.CompletedProcess([], 0, stdout="Validating package...\n"),
             ]) as run:
            package_verify.main()
        version.assert_called_once_with([flutter, "--version", "--machine"], text=True)
        self.assertEqual(run.call_args_list[0].args[0], [flutter, "pub", "get"])

    def test_required_smokes_reject_missing_fixtures_before_invoking_flutter(self):
        tool = Path(__file__).resolve().parents[1] / "tool/verify.py"
        for arguments in (["native"], ["web"], ["device", "--model-url", "https://example.test/model.gguf"]):
            result = subprocess.run([sys.executable, str(tool), *arguments, "--flutter", "/nonexistent/flutter"], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_publish_gate_rejects_unexpected_warnings(self):
        with patch.object(sys, "argv", ["verify.py", "package", "--flutter", "flutter"]), \
             patch.object(package_verify.subprocess, "check_output", return_value='{"frameworkVersion":"3.47.1"}'), \
             patch.object(package_verify.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0),
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
                    fetch_web_assets.main()
            self.assertEqual(downloaded, ["manifest.json"])
            self.assertEqual(sentinel.read_bytes(), b"existing runtime")

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
