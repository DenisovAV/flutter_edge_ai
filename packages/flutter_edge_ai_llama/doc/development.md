# Contributor checks

Use the connector CI SDK, Flutter 3.47.1 / Dart 3.13.1, for reproducible formatting.
The runner also accepts the workspace SDK, Flutter 3.47.0. Other versions are
rejected to keep formatting checks reproducible. The package minimum follows core: Flutter 3.44 / Dart 3.12. The root workspace
SDK and shared workflow settings remain upstream-owned.

From the package directory:

```sh
python3 tool/verify.py contracts
python3 tool/verify.py package
python3 tool/fetch_test_model.py
python3 tool/verify.py native --model-path tool/fixtures/chat.gguf
python3 tool/verify.py build --platform web
python3 tool/verify.py device --device <device-id> --model-url <model-url>
```

The package gate copies the standalone package, removes workspace resolution,
and validates hosted core 2.3.2+ without a development override. It does not publish.
Required native, packaged-device and Web model lanes inspect Flutter's JSON test
report and require their real-model test to complete successfully, without skipping.

For the real Web smoke, first serve the fixture and storage helper:

```sh
python3 tool/serve_web_fixture.py --model-path tool/fixtures/chat.gguf
# In another terminal:
python3 tool/verify.py web --model-url http://127.0.0.1:8098/chat.gguf \
  --storage-helper-url http://127.0.0.1:8098/cache_api.js
```

The Web runner requires Linux/macOS and Chrome. Its temporary local proxy adds
worker isolation headers omitted by the Flutter test server; runtime bytes stay
unchanged. Production hosting must set its own COOP/COEP headers.

## Model-specific capabilities

Each selected feature requires its own compatible fixtures. A missing fixture or
skipped/absent selected test fails the lane. These examples qualify native VM paths:

```sh
python3 tool/verify.py capabilities --capability tools --model-path /absolute/qwen.gguf
python3 tool/verify.py capabilities --capability vision --model-path /absolute/model.gguf \
  --projector-path /absolute/mmproj.gguf --input-path /absolute/image.png
python3 tool/verify.py capabilities --capability audio --model-path /absolute/model.gguf \
  --projector-path /absolute/mmproj.gguf --input-path /absolute/audio.wav
python3 tool/verify.py capabilities --capability lora --model-path /absolute/base.gguf \
  --adapter-path /absolute/adapter.gguf
python3 tool/verify.py capabilities --capability gpu --model-path /absolute/model.gguf
```

A VM capability pass is not packaged mobile or GPU qualification on another host.
Record the revision, model checksum, platform/device, backend, command and result
in the PR. The [current matrix](platforms.md) lists remaining qualification gaps.
Core-only changes run contracts; connector/shared-build changes also run release
and device jobs, which additionally run nightly and on dispatch.
