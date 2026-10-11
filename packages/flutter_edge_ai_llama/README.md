# Flutter Edge AI llama.cpp engine

GGUF inference and embedding connectors with example runners for Android, iOS,
macOS, Windows, Linux and Web. Platform and feature qualification are recorded
separately in [the support matrix](doc/platforms.md).
Pinned APIs: `flutter_edge_ai 2.1.3`, `llamadart 0.11.1`. The iOS/macOS demo uses
`llamadart_llama_cpp_flutter 0.0.21` for Apple's SwiftPM runtime linkage.
The adapter lives in `packages/flutter_edge_ai_llama/` and resolves core from
the monorepo workspace during development. Standalone consumer validation uses
the exact published versions above. This package is being prepared for
contribution; publication and final maintainer ownership remain pending.

## Try the demo

Run these commands from `packages/flutter_edge_ai_llama/`.

With Flutter 3.47.1 / Dart 3.13.1:

```sh
cd example
flutter pub get
flutter run -d macos
# Web only: prepare the unmodified runtime assets first.
cd ..
python3 tool/fetch_web_assets.py
cd example
flutter run -d chrome \
  --web-header Cross-Origin-Opener-Policy=same-origin \
  --web-header Cross-Origin-Embedder-Policy=require-corp
```

On native platforms, **Choose model** imports an instruction-tuned `.gguf` into
app-owned storage with a file copy, avoiding a full-model Dart buffer. Imported
models use additional disk space; the original is preserved. The installed model
is restored at startup where core can recover its identity. macOS App Sandbox
remains enabled. On Web, enter a
CORS-enabled GGUF URL and use **Load URL**. The browser loads the bridge asset
pin shipped with llamadart 0.11.1 (`v0.1.54`). The preparation script downloads
and checks the release manifest, sizes and SHA-256 values from jsDelivr; the
build then serves those unmodified assets from the app's origin, as required
by the runtime's workers. It also includes core's pinned `cache_api.js` helper
and license. Deploy with COOP `same-origin` and COEP `require-corp` headers.
Model URLs must allow CORS and cross-origin resource access. Large browser
blobs can exceed browser memory limits.

The demo uses a 2,048-token context and 128-token output budget. CPU/GPU is read
from the loaded runtime. **Stop** rolls back the interrupted turn in both the
connector and visible UI; another message can follow without resetting.
**New chat** clears the conversation. Backgrounding the native demo cancels an
active turn. Streamed text refreshes at most every 33 ms without rebuilding the
whole screen, and scrolling respects readers inspecting earlier messages.
Context overflow fails explicitly;
automatic context compaction is not implemented.

## Integration

Select llama.cpp only in your **application's** `pubspec.yaml` before building:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Merge this into any existing hook configuration. For a pub workspace, put it
in the workspace root's `pubspec.yaml`. Flutter reads hook user-defines from
that root; this connector's own settings do not propagate to dependent apps.
Without this selection, published `llamadart 0.11.1` includes both llama.cpp
and LiteRT-LM on native targets where LiteRT-LM is available. Registering only
`LlamaEngineProvider` controls inference routing, not build-time native assets.

The pinned `flutter_edge_ai 2.1.3` core does not bundle a LiteRT-LM runtime;
its engines are separate opt-in packages. This connector uses llama.cpp for
GGUF inference and embeddings. To keep your app llama.cpp only, also omit
`flutter_edge_ai_litertlm` and `llamadart_litert_lm_flutter` dependencies.
Apple Flutter apps need the matching `llamadart_llama_cpp_flutter 0.0.21`
companion as a direct app dependency with SwiftPM enabled, as in the example.
Web uses the llama.cpp bridge assets described above; native hook selection
does not change Web assets.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [LlamaEngineProvider()],
  embeddingBackends: const [LlamaEmbeddingProvider()],
);
// Call after initialization to restore an imported GGUF after restart.
await restoreInstalledLlamaModel();

await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.binary,
).fromFile('/absolute/model.gguf').install();

final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final chat = await model.openChat(enableThinking: true, maxOutputTokens: 256);
await chat.addQuery(Message.text(text: 'Hello', isUser: true));
await for (final response in chat.generateChatResponseAsync()) {
  switch (response) {
    case TextResponse(:final token): print(token);
    case ThinkingResponse(:final content): print(content);
    case FunctionCallResponse() || ParallelFunctionCallResponse(): break;
  }
}
await model.close();
```

`createSession`/`createChat` retain the legacy singleton behavior: a replacement
closes the old legacy session. `openSession`/`openChat` create independent
transcripts over the same loaded weights. Inference and tokenization serialize
through one runtime queue; these sessions do not allocate independent native
KV caches or run inference in parallel. `maxConcurrentSessions` caps detached
sessions. Closing a model cancels and closes all its sessions.

## Tools and thinking

Pass tools with object JSON Schemas and `ToolChoice.auto`, `required`, or `none`.
The connector forwards the complete schemas to llamadart and uses its typed
outputs, without Edge AI's model-family parser or a synthetic LiteRT JSON
response. A compatible model/template/runtime is still required. `required`
uses llamadart's grammar path where supported and fails if no call is returned.
Malformed or undeclared calls are rejected before history is committed.

```dart
final chat = await model.openChat(tools: [
  const Tool(name: 'weather', description: 'Get weather', parameters: {
    'type': 'object',
    'properties': {'city': {'type': 'string'}},
    'required': ['city'],
  }),
]);
await chat.addQuery(Message.text(text: 'Weather in Montreal?', isUser: true));
await for (final response in chat.generateChatResponseWithTools(
  onToolCall: (call) async => {'temperature': 18},
)) {
  if (response is TextResponse) print(response.token);
}
```

The bounded Edge AI tool loop is inherited. For manual execution, calls are
`LlamaFunctionCallResponse` instances retaining the call ID. Answer with
`LlamaToolResponseMessage(callId: call.id, toolName: call.name, response: result)`.
Ordinary `Message.toolResponse` remains compatible, matching unanswered calls
by name in emission order. Use explicit IDs for out-of-order results when
several calls have the same name. Reused runtime call IDs are remapped to keep IDs unique across turns.
Calls commit before being delivered; all
calls must be answered before the next generation.

Thinking deltas become `ThinkingResponse` only when `enableThinking` is true.
The model can ignore the thinking switch; hidden reasoning still consumes
runtime/output budget. The low-level String session methods return answer text
and JSON tool calls; use the connector chat or session `getResponses()` for
typed thinking and tools. The synchronous chat response follows Edge AI's
single-response API: it returns a call group when present, otherwise joined text.

## Images, audio and LoRA

Configure a model-specific projector resolver on `LlamaEngineProvider`:

```dart
import 'package:llamadart/llamadart.dart' as llama;

final provider = LlamaEngineProvider(
  projectorResolver: (spec, config) async =>
      llama.ModelSource.path('/absolute/mmproj.gguf'),
);
```

Use a browser URL with `llama.ModelSource.path(...)` on Web. The app owns projector
installation and exact model/projector pairing: core has no GGUF projector
slot. The connector probes the loaded projector's vision/audio capabilities.
Set `supportImage`/`supportAudio` on `getActiveModel` and enable the corresponding
chat/session modality. Encoded image/audio bytes map directly to llamadart
content parts; `maxNumImages` is enforced per input message. The text-template
budget preflight does not estimate media embeddings; the runtime enforces its
actual multimodal context requirements. Separate encoder backend overrides
are unavailable in llamadart and fail explicitly.

Native sessions accept `loraPath`, applying the adapter during their exclusive
turn and removing it before a peer runs. Installed `InferenceModelSpec`
LoRA companions are resolved through core's file manager and used by default.
If applying/removing an adapter fails, the shared runtime is invalidated:
close/reload the model before any peer can infer with uncertain adapter state.
Web LoRA operations are unavailable in llamadart 0.11.1 and remain unsupported.
Core does not persist the inference LoRA companion in its restart identity;
after restart, reinstall the paired spec or pass `loraPath` explicitly.

## Embeddings

Register `LlamaEmbeddingProvider` in `embeddingBackends`. Use a trained embedding
GGUF, not a chat model. The runtime uses its embedded tokenizer; the current
core installation API still requires a tokenizer companion, which this backend
does not read. For BGE/MiniLM-like models disable Edge AI's EmbeddingGemma-specific
task prefixes; for compatible EmbeddingGemma models keep the default.

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: const [
    LlamaEmbeddingProvider(useTaskPrefixes: false, contextSize: 512),
  ],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromFile('/absolute/bge-small-en-v1.5-q8_0.gguf')
    .tokenizerFromFile('/absolute/tokenizer.json')
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vectors = await embedder.generateEmbeddings(['cat', 'dog']);
final dimension = await embedder.getDimension();
await embedder.close();
```

Single/batch results preserve order, are normalized by llamadart, and are checked
for empty/nonfinite/all-zero vectors and changing dimensions. Embedding calls
serialize with safe shutdown; close notifications evict core's cached embedder.
`getDimension()` probes an embedding only until the first valid vector exists.

## Compatibility boundaries

Core 2.1.3 has no `ModelFileType.gguf`; only binary specs with a `.gguf` primary
filename are claimed. Other runtimes/formats remain unclaimed. Upstream GGUF
identity, extension classification, an optional embedding tokenizer slot, and
projector/LoRA persistence would remove the documented compatibility shims.
`restoreInstalledLlamaModel()` compensates for core's imported-file restore path
through its pinned identity and activation libraries; it never downloads or
activates a different saved source. Missing or malformed identities return false.

Core Web probes a synthetic `web-active` / `active.bin` spec. The connector
recovers the active installed identity for that exact probe before selecting
and loading it; unrelated binary formats are still rejected.
Web resolves core's installed blob/network URLs. Use `WebStorageMode.cacheApi`
or `none`; OPFS stream handles are not accepted by llamadart's URL loader.
Missing bridge assets, unavailable GPU, unsupported projector/template grammar
combinations and runtime capability skew fail with actionable errors. NPU,
LiteRT activation/MTP controls and MediaPipe LoRA ranks remain unsupported for
this GGUF adapter. They describe other engines and cannot be meaningfully
forwarded to llama.cpp through this contract.

Explicit GPU requests fail if the runtime reports zero GPU layers; unknown
backend identity remains unknown. Runtime usage drives metrics; output tokens are zero/unknown when usage is not
reported. Throughput includes prefill. The demo labels missing output counts as unavailable. Native termination is available as
`LlamaInferenceSession.lastFinishReason`. Only completed turns commit history;
cancellation/error removes pending input and partial output.

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
  build/device evidence is in [doc/platforms.md](doc/platforms.md).

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
