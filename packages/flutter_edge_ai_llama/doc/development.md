# Contributor checks

For app setup, use the [package README](../README.md). For current platform
evidence and release gates, use the [qualification matrix](platforms.md).
The model-specific evidence below includes the original POC and must be read
alongside the dated migration evidence in that matrix.

## Validation

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test example/lib example/test
flutter analyze
flutter test test/connector_test.dart
flutter test test/connector_test.dart test/web_smoke_test.dart --platform chrome
python3 tool/fetch_web_assets.py
# Serve a CORS-enabled model and the storage helper; model test is opt-in.
python3 tool/run_web_smoke.py --model-url https://your-host/model.gguf \
  --storage-helper-url https://your-host/cache_api.js
flutter test test/native_smoke_test.dart \
  --dart-define=GGUF_MODEL_PATH=/absolute/chat.gguf
flutter test test/native_capabilities_test.dart \
  --dart-define=GGUF_TOOL_MODEL_PATH=/absolute/qwen.gguf \
  --dart-define=GGUF_EMBEDDING_MODEL_PATH=/absolute/bge.gguf
python3 tool/fetch_web_assets.py
cd example
flutter test
flutter build macos --release
flutter build web --wasm --release
cd ..
python3 tool/validate_web_build.py
```

Native capabilities have independent opt-in defines for audio model/projector/
WAV, vision model/projector/PNG, LoRA base/adapter and GPU model. See
`test/native_capabilities_test.dart`. Unconfigured model tests skip. To test
embedding install/restart with the facade smoke, also supply
`GGUF_EMBEDDING_MODEL_PATH` and `GGUF_TOKENIZER_PATH`.

The real Web smoke runner requires a POSIX host (Linux or macOS) and uses Chrome and Flutter's Wasm test mode. Flutter
3.47.1 omits COEP on test worker scripts even with `--cross-origin-isolation`;
the runner starts a temporary local header proxy scoped to the test's runtime
asset requests. It forwards unchanged bytes, adds isolation headers, and stops
with the test. It does not change the installed SDK or browser settings. Supply
`--flutter`/`--chrome` when their executables are not at the defaults. Core's
storage helper URL defaults to `cache_api.js` next to the model URL.

Recorded macOS arm64 evidence with the pinned SDK:

- 32 VM contract tests and 31 Chrome contracts (including Web identity routing);
  Chrome omits the two native LoRA tests.
- Real facade file installation, two-turn memory, cancellation, reload,
  imported-model restart fallback, embedding install and embedding restart: PASS.
- Qwen3-0.6B-Q8_0 typed thinking and required tools, CPU: PASS.
- ggml-org BGE-small-en-v1.5-Q8_0, CPU: normalized 384-dimensional embeddings,
  batch order and semantic similarity check PASS.
- Qwen3-ASR-0.6B-Q8_0 + matching projector, encoded WAV, CPU: PASS.
- GLM-OCR.i1-Q4_K_M + matching Q8 projector, encoded PNG, Metal: PASS.
- stories15M_MOE-Q8_0 + moe_shakespeare15M adapter, CPU: adapter/base alternation PASS.
- SmolLM2-135M-Instruct-Q8_0 explicit Metal execution: PASS.
- Chrome 154, real facade network installation → installed blob → dedicated
  worker/Wasm GGUF text generation with SmolLM2-135M-Q8_0: PASS. CPU was requested;
  the Web runtime reports no resolved GPU-layer count, so accelerator identity
  is unknown and this is not hardware WebGPU qualification.
- Two demo widget sizes and macOS/Web debug builds: PASS.
- This original POC record predates the production-hardening pass; current
  build/device evidence is in [platforms.md](platforms.md).

The first cstr MiniLM artifact was rejected by llama.cpp for missing
`bert.token_type_count`; it was not patched. The verified BGE artifact is
[ggml-org/bge-small-en-v1.5-Q8_0-GGUF](https://huggingface.co/ggml-org/bge-small-en-v1.5-Q8_0-GGUF)
at revision `f2068edd9b54f2a369549ccc71f70ed273a2a801`, SHA-256
`f046db1dc724cf4f6f0a0c5917e922823b73eb1d27b8f9a9c2797f7866974804`.
Real Web tools/thinking/media/embeddings and hardware WebGPU execution have
not been model-qualified in this POC. Their connector contracts are covered;
requesting a capability still requires a compatible runtime and model.


## Package gates

```sh
python3 tool/verify.py contracts
python3 tool/verify.py package
python3 tool/fetch_test_model.py
python3 tool/verify.py native --model-path tool/fixtures/chat.gguf
# Windows native lane uses the packaged app; macOS/Linux use the VM facade.
python3 tool/verify.py build --platform android
# Also: ios, macos, windows, linux, web, on a compatible build host.
```

The repository workflow `.github/workflows/llama.yml` builds all six
platforms, tests real native CPU inference on three desktop hosts, runs Android/iOS
packaged CPU smokes, packaged Linux/Windows lifecycle checks, and tests real browser
CPU generation. These jobs become
qualification evidence only after they pass on the actual revision. GPU and
advanced model families have independent qualification requirements.

The package-content dry-run removes workspace resolution in a clean standalone
copy so workspace configuration or enclosing archive exclusions cannot hide
consumer resolution problems or metadata. It does not publish. It reports two
intentional exact-pin warnings and a changelog-version warning while this work is unreleased;
`tool/verify.py package` rejects any other warning or validation error. A release
must choose repository metadata and a version, cut the changelog, complete the
platform matrix and run independent review before publication.
