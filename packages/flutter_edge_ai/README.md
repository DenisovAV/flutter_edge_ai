# Flutter Edge AI

[![CI Tests](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml)
[![Release Build](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml)
[![pub package](https://img.shields.io/pub/v/flutter_edge_ai.svg)](https://pub.dev/packages/flutter_edge_ai)

On-device AI for Flutter on Android, iOS, Web, macOS, Windows and Linux. Run
any model a registered engine supports
([models](https://flutteredge.ai/docs/models)), or the model the operating
system already ships, with text, vision, audio, function calling, embeddings,
RAG and speech — no server, no cloud. The core is small: you add only the
runtimes and stores your app uses.

<p align="center">
  <img src="https://flutteredge.ai/images/readme-banner.png" alt="Flutter Edge AI — on-device LLMs in your Flutter app">
</p>

> **Formerly `flutter_gemma`.** Through 1.11.4 this package shipped as
> `flutter_gemma`. Version 2.0 also moves RAG out of core into
> `flutter_edge_ai_rag`, and 2.3.0 changes the embedding API. See the
> [migration guide](MIGRATION.md).

📖 Full documentation: **[flutteredge.ai](https://flutteredge.ai)**

## Features

- **Pluggable engines:** LiteRT-LM (`.litertlm`), MediaPipe (`.task`), ONNX Runtime, llama.cpp (`.gguf`), and the OS's own models (Gemini Nano, Apple Foundation Models, Windows AI Foundry, Chrome Prompt API).
- **Multimodal:** image and audio input on the models that support it.
- **Function calling** and **thinking mode** on the models that support them.
- **CPU, GPU and NPU** backends — Qualcomm on Android and Linux arm64, Google
  Tensor and MediaTek on Android (all opt-in), and Intel on Windows.
- **Embeddings and on-device RAG:** text, image and audio embeddings (EmbeddingGemma 2 and 1, Gecko, ONNX models — [models](https://flutteredge.ai/docs/models)) with nine task types, stored in Qdrant Edge or SQLite + `sqlite-vec`, payload filters included.
- **Speech:** on-device STT, TTS and a push-to-talk voice loop.
- **Agent skills:** `SKILL.md` tools the model invokes through function calling.
- **Model management:** installs from the network, assets, bundled files or local paths; Hugging Face installs in one call; retries, typed download errors, LoRA weights (MediaPipe `.task` models, and GGUF models through llama.cpp on native platforms).
- **Genkit** integration for on-device and hybrid cloud flows.

## Packages

Core registers no engine. Add `flutter_edge_ai` plus what your app needs:

| You want to… | Add |
|---|---|
| Run any `.litertlm` model, and LiteRT embeddings | [`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm) |
| Run `.task` / `.bin` models (MediaPipe; mobile and web; maintenance-only upstream, prefer `.litertlm`) | [`flutter_edge_ai_mediapipe`](https://pub.dev/packages/flutter_edge_ai_mediapipe) |
| Run GGUF chat and native EmbeddingGemma 2 text embeddings through llama.cpp | [`flutter_edge_ai_llama`](https://pub.dev/packages/flutter_edge_ai_llama) |
| Run ONNX models — text generation and embeddings | [`flutter_edge_ai_onnx`](https://pub.dev/packages/flutter_edge_ai_onnx) |
| Use the model built into the OS or browser | [`flutter_edge_ai_builtin_ai`](https://pub.dev/packages/flutter_edge_ai_builtin_ai) |
| Tokenizers for text embeddings (needed for `.tflite` / `.onnx` embedders; an EmbeddingGemma 2 `.litertlm` carries its own) | [`flutter_edge_ai_embeddings`](https://pub.dev/packages/flutter_edge_ai_embeddings) |
| On-device RAG | [`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag) + [`flutter_edge_ai_qdrant`](https://pub.dev/packages/flutter_edge_ai_qdrant) (native) or [`flutter_edge_ai_sqlite`](https://pub.dev/packages/flutter_edge_ai_sqlite) (all six platforms) |
| Speech-to-text, text-to-speech, voice loop | [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech) |
| Agent skills over function calling | [`flutter_edge_ai_agent`](https://pub.dev/packages/flutter_edge_ai_agent) |
| Memory a model costs, read from the OS | [`flutter_edge_ai_diagnostics`](https://pub.dev/packages/flutter_edge_ai_diagnostics) |
| Genkit, and on-device/cloud routing | [`genkit_flutter_edge_ai`](https://pub.dev/packages/genkit_flutter_edge_ai), [`genkit_hybrid`](https://pub.dev/packages/genkit_hybrid) |

## Supported platforms

| Engine | Android | iOS | Web | macOS | Windows | Linux |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| LiteRT-LM (`.litertlm`) | ✅ | ✅ | ⚠️ preview ¹ | ✅ | ✅ | ✅ |
| MediaPipe (`.task`) | ✅ | ✅ ² | ✅ | — | — | — |
| ONNX Runtime | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| llama.cpp (`.gguf`) ³ | ✅ | ✅ ⁴ | ✅ | ✅ ⁴ | ✅ | ✅ |
| Built-in AI | ✅ | ✅ | ✅ | ✅ | ✅ | — |

¹ Web `.litertlm` takes text input only — an image or audio message throws `UnsupportedError`; function calling and thinking work.

² CPU only: a GPU `.task` does not load on iOS; use a `.litertlm` for the iOS GPU.

³ Through llamadart; CI covers the CPU lifecycle — see its [qualification matrix](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md).

⁴ iOS 16.4+ and macOS 14+, with Flutter's Swift Package Manager on and the `llamadart_llama_cpp_flutter` companion. From `flutter_edge_ai_litertlm` 1.19.0 LiteRT-LM needs no Podfile on macOS either, and both libraries load in one Swift Package Manager app; running both engines' models in one app is not qualified. See the [`flutter_edge_ai_llama` README](https://pub.dev/packages/flutter_edge_ai_llama).

LiteRT-LM ships `arm64` on Android, iOS and macOS, `x86_64` on Windows and `x86_64` / `arm64`
on Linux; on Android, MediaPipe `.task` also runs on `x86_64` / `armeabi-v7a`, and on Linux
ONNX is `x86_64` only. Details, GPU backends and per-feature limits:
[installation](https://flutteredge.ai/docs/installation#platform--architecture-support).

## Installation

```yaml
dependencies:
  flutter_edge_ai: ^2.5.4
  flutter_edge_ai_litertlm: ^1.19.0   # or any other engine from the table
```

> **Upgrade every flutter_edge_ai package together.** Minimum versions with
> core 2.3.0: `flutter_edge_ai_litertlm` 1.13.0 · `flutter_edge_ai_embeddings`
> 2.3.0 · `flutter_edge_ai_onnx` 0.5.8 · `flutter_edge_ai_mediapipe` 1.2.2 ·
> `flutter_edge_ai_builtin_ai` 0.3.5 · `flutter_edge_ai_speech` 0.5.6 ·
> `flutter_edge_ai_agent` 0.2.9 · `flutter_edge_ai_rag` 1.1.0 ·
> `flutter_edge_ai_sqlite` 2.1.0 · `flutter_edge_ai_qdrant` 2.1.0 ·
> `genkit_flutter_edge_ai` 0.9.1. An older engine or store fails to compile
> against 2.3.0; see the [migration guide](MIGRATION.md). With core 2.4.0,
> `getActiveModel(multimodalOrder:)` and `activeVisionBackend` /
> `activeAudioBackend` need `flutter_edge_ai_litertlm` 1.14.0, and Genkit tool
> call ids need `genkit_flutter_edge_ai` 0.10.0; older versions compile against
> 2.4.0 but ignore them.

Then complete the platform setup below.

## Platform setup

### iOS

Set the deployment target to **15.0** (**16.0** if you use
`flutter_edge_ai_mediapipe`, **16.4** with `flutter_edge_ai_llama` ⁴) and link
pods statically in `ios/Podfile`:

```ruby
platform :ios, '15.0'
use_frameworks! :linkage => :static
```

For large models add `com.apple.developer.kernel.extended-virtual-addressing`,
`com.apple.developer.kernel.increased-memory-limit` and
`com.apple.developer.kernel.increased-debugging-memory-limit` to
`Runner.entitlements`. The iOS Simulator runs on CPU only.

### Android

Release builds need `<uses-permission android:name="android.permission.INTERNET"/>`
in `android/app/src/main/AndroidManifest.xml` to download models (Flutter's
template adds it only to the debug and profile manifests). Anything backed by
LiteRT — `.litertlm`, LiteRT embeddings, speech — needs `minSdk 30` and is
`arm64-v8a` only. `flutter_edge_ai_builtin_ai` needs `minSdk 26` (and macOS
12.0). The GPU and NPU `uses-native-library` entries still merge in from the
plugin manifest automatically.

### Web

Copy `cache_api.js` and `opfs_helper.js` from this package's `web/` folder into
your app's `web/` and load them inside the `<head>` of `index.html`, then add
the script for each engine you use. For MediaPipe:

```html
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.30';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

The LiteRT-LM, ONNX, web embeddings and SQLite snippets are in the
[web setup guide](https://flutteredge.ai/docs/installation#web). MediaPipe and
LiteRT-LM run on WebGPU; ONNX also runs on CPU (WASM).

### macOS

macOS 14 or later: set the app's deployment target to 14.0 (Xcode → Runner
target → General → Minimum Deployments, and `platform :osx, '14.0'` in
`macos/Podfile` if the app has one).

With Flutter's default Swift Package Manager on, that is all: from
`flutter_edge_ai_litertlm` 1.19.0 its Swift package brings LiteRT-LM's companion
libraries into the app ([why](https://flutteredge.ai/docs/desktop#macos)).

An app with Swift Package Manager off (`enable-swift-package-manager: false`
under `flutter: config:` in `pubspec.yaml`) gets them from `macos/Podfile`:
replace its `post_install` block with the one below, keeping any lines of your
own inside it; the next build runs `pod install` itself. Without it the first
model load fails with `LiteRT-LM did not load on macOS`.

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  # flutter_gemma: stage the upstream Apple companion dylibs into the built
  # .app. `hook/build.dart` deliberately skips them from Native Assets on macOS
  # (#247 — Google ships them without `-Wl,-headerpad_max_install_names`, so the
  # JIT bundling path cannot rewrite their install_name), which leaves this
  # build phase to stage them.
  #
  # The phase only LOCATES and RUNS a script; the staging logic itself lives in
  # flutter_edge_ai_litertlm and is delivered next to the dylibs it stages. That
  # is deliberate: this block is frozen into your Xcode project, and a copy of
  # the logic frozen there cannot be fixed by upgrading the package.
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_targets.each do |user_target|
      phase_name = '[flutter_gemma] Setup LiteRT-LM macOS'

      # Only the app target embeds the Frameworks/ this phase patches.
      # RunnerTests inherits Runner's framework search paths and has no
      # Contents/Frameworks of its own — having the phase there creates a
      # cross-target dependency on Runner's framework output that Xcode reports
      # as "Cycle inside Flutter Assemble" (#300). Remove any stale copy from
      # non-app targets and skip them.
      unless user_target.name == 'Runner'
        user_target.build_phases
          .select { |p| p.respond_to?(:name) && p.name == phase_name }
          .each { |p| user_target.build_phases.delete(p) }
        next
      end

      existing = user_target.shell_script_build_phases.find { |p| p.name == phase_name }
      phase = existing || user_target.new_shell_script_build_phase(phase_name)
      # The embedded LiteRtLm binary is an INPUT so the phase re-runs whenever
      # Flutter's always-out-of-date `embed` phase re-copies the raw, unpatched
      # binary over the patched one. Without it Xcode caches the phase after the
      # first build and the second incremental build ships an unpatched
      # LiteRtLm that fails dlopen at runtime (#368).
      phase.input_paths = [
        '$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
      ]
      # A declared output lets Xcode order the phase in its dependency graph
      # instead of treating it as "runs every build with no outputs" — the other
      # half of the cycle warning (#300). The script touches this file.
      phase.output_paths = ['$(DERIVED_FILE_DIR)/flutter_gemma_litertlm_macos.stamp']
      phase.shell_script = <<~SHELL
        set -e
        STAGER="${HOME}/Library/Caches/flutter_gemma/native/macos_arm64/stage_macos_companions.sh"
        if [ ! -f "${STAGER}" ]; then
          echo "[flutter_gemma] ERROR: ${STAGER} not found." >&2
          echo "  flutter_edge_ai_litertlm installs it there from its build hook." >&2
          echo "  Upgrade the package, then: flutter clean && flutter pub get" >&2
          exit 1
        fi
        sh "${STAGER}" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        touch "${SCRIPT_OUTPUT_FILE_0}"
      SHELL
    end
  end
end
```

**Flutter 3.44 with Xcode 27.** With Swift Package Manager off, the first
build stops with `The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set
to 10.15, but the range of supported deployment target versions is 12.0 to
27.0.x` on the Pods targets, `FlutterMacOS` among them. This is Flutter 3.44.0
on Xcode 27, not this package: an app with only `shared_preferences` and Swift
Package Manager off fails the same way. Add one line inside the
`installer.pods_project.targets.each` loop of the block above, after
`flutter_additional_macos_build_settings(target)`:

```ruby
target.build_configurations.each { |c| c.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0' }
```

Flutter 3.47.8 builds the same Podfile without it (measured on Xcode 27.1,
2026-10-28).

Add to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

With Swift Package Manager off, also add
`com.apple.security.cs.disable-library-validation`: the Podfile block signs the
companion libraries ad hoc, which Hardened Runtime refuses without it.

### Windows and Linux

Nothing to add: the native libraries are downloaded and bundled at build time.
GPU on Linux needs a vendor Vulkan driver (NVIDIA, AMD or Intel) — Mesa's
`llvmpipe` is not enough for Gemma 4.

## Quick start

### Initialization

Register the engines you added, once, in `main()`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine()],
    // Gated Hugging Face models need a token; never hard-code it.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isEmpty
        ? null
        : const String.fromEnvironment('HUGGINGFACE_TOKEN'),
  );
  runApp(const MyApp());
}
```

### Install a model

Once per device; installed models survive restarts, `fromFile` ones included.
Installing a name again from another source replaces it; core never deletes a
file you installed with `fromFile`.

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm, // selects the engine — declare it
).fromNetwork(
  'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
).withProgress((progress) => print('Downloading: $progress%')).install();
```

`litert-community/Gemma3-1B-IT` is gated: accept its license on Hugging Face, then pass your token with `--dart-define=HUGGINGFACE_TOKEN=…`.

### Chat

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat = await model.createChat();

await chat.addQueryChunk(Message.text(text: 'Explain quantum computing', isUser: true));

// Stream the reply token by token:
final reply = StringBuffer();
await for (final response in chat.generateChatResponseAsync()) {
  if (response is TextResponse) reply.write(response.token);
}

await model.close();
```

`getActiveModel` returns the same model while the active model and its
arguments stay the same. Another model, or other arguments, builds a new one
and closes the previous handle. A model is closed from the moment its
`close()` starts (`model.isClosed`); `getActiveModel` waits for that close to
finish, then builds a new model. With no model installed it throws
`NoActiveModelError`, a `StateError`.

To keep several models loaded at once, such as one file on CPU and GPU, open
them with `FlutterEdgeAi.openModel(spec, …)` on a spec from
`installModel(…).install(activate: false)`, with `LiteRtLmEngine`
(`flutter_edge_ai_litertlm` 1.16.0) on Android, iOS and desktop. Each call
builds a model the app owns and closes; see
[Desktop → Several models at once](https://flutteredge.ai/docs/desktop#several-models-at-once).

Sampling left unset comes from the model: the sampler a native `.litertlm` file
ships, else the defaults its family publishes (`SamplingParams.forModelType`),
else `topK: 40`. Pass `topK: 1` for greedy decoding. What each engine reads,
and why `.litertlm` keeps the first session's values:
[Sampling](https://flutteredge.ai/docs/getting-started#sampling).

### Decide (experimental)

Pick one of N options — an intent, an action, a screen, a tool — for an input,
or abstain when none fits. Every embedding model can do it:

```dart
// ignore_for_file: experimental_member_use
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final decider = await embedder.createDecider(options: [
  DeciderOption('set_timer', examples: [
    EmbeddingInput.text('set a timer for ten minutes'),
    EmbeddingInput.text('wake me in half an hour'),
  ]),
  DeciderOption('call_contact', examples: [
    EmbeddingInput.text('call mum'),
    EmbeddingInput.text('ring Alex on his mobile'),
  ]),
]);
final answer = await decider.choose(
  DeciderInput(EmbeddingInput.text('remind me in 20 minutes')),
);
print(answer.choice ?? 'none of these (${answer.abstainReason})');
```

Options and inputs are embedded with `TaskType.sentenceSimilarity`; an option
is the centroid of its examples (and description). The decider abstains when the
input's best cosine is below a threshold cross-fitted on the options' own
examples. Store a fitted decider with `toArtifact()` and restore it with
`loadDecider` — pinned to its embedding space, so a CPU-fitted decider is never
loaded onto an NPU bundle. Measured with EmbeddingGemma 2 on CLINC150 and
HWU64, the numbers and their limits:
[Decisions](https://flutteredge.ai/docs/decisions).
`InferenceModel.createDecider(question:, options:, calibration:)` is the
language-model kind, with answers of the same shape: a small `.litertlm` tuned
for the decision by LiteTune carries the question, options, temperature and
threshold in the file; pass the question and the options, with
`InferenceDeciderCalibration.fromModel()` for the rest. Each option's id is
scored as the model's reply, natively, on the CPU (`flutter_edge_ai_litertlm`
1.16.0) or the GPU (1.20.0; not the NPU). It answers Choice, Noul (`answer.noul`, P(yes)) and Score
(`answer.expectedLevel`) questions.

## Three things that fail quietly

- **`maxTokens` is the context window**, not the reply length: prompt, history
  and answer together. `.litertlm` needs at least 1024. Cap the reply with
  `createChat(maxOutputTokens: …)` (`.litertlm`; MediaPipe ignores it).
- **`Message.isUser` defaults to `false`.** A user message without
  `isUser: true` gets an empty answer.
- **`fileType` picks the engine**, not the file name. `installModel` defaults
  to `ModelFileType.task`, so a `.litertlm` must say `ModelFileType.litertlm`.

## Supported models

Any model a registered engine runs. Which models run on which engine and
platform, the `ModelType` to install each with, function calling, thinking,
vision and audio support, and download links:
[models](https://flutteredge.ai/docs/models).

Embedding models: EmbeddingGemma 1 and Gecko (`.tflite` plus a tokenizer,
every platform) and EmbeddingGemma 2 (one `.litertlm` file: text, images on
the 440m and 740m bundles, audio on the 740m, and several parts in one vector
with `EmbeddingInput(text:, images:, audio:)`, natively and on the Web), all
through `flutter_edge_ai_litertlm`; MiniLM-class
`.onnx` models through `flutter_edge_ai_onnx`. Download links, sizes, formats
per platform, embedding and speech models:
[models](https://flutteredge.ai/docs/models).

Core 2.5.0 lets embedding providers accept self-contained `.gguf` files without
a separate tokenizer. The opt-in `LlamaEmbeddingBackend` in
`flutter_edge_ai_llama` 0.0.3 runs native EmbeddingGemma 2
text embeddings through llamadart. Give GGUF its own RAG vector profile;
equal dimensions do not make GGUF and LiteRT vectors interchangeable.
`flutter_edge_ai_embeddings` supplies tokenizers only and owns no runtime.
Providers declare capabilities with
`EmbeddingBackendProvider.honouredBackends(spec)` and report the loaded
accelerator through `EmbeddingPassInfo.activeBackend`. Automatic requests reuse
the current non-NPU embedder for the same model. Repeated explicit CPU/GPU
requests reuse the model they loaded, including a fallback, until a rebuild is
needed or the model is closed; the fallback warning is printed once per load.
Core keeps ownership of
the model cache, worker and close lifecycle. Existing providers keep their
CPU/NPU cache behavior.

## Going further

- [Getting started](https://flutteredge.ai/docs/getting-started) — sessions, system instructions, removing models
- [Models](https://flutteredge.ai/docs/models) — model sources, Hugging Face installs
- [Function calling](https://flutteredge.ai/docs/function-calling) · [Multimodal](https://flutteredge.ai/docs/multimodal) · [Thinking mode](https://flutteredge.ai/docs/thinking-mode)
- [Embeddings & RAG](https://flutteredge.ai/docs/embeddings-and-rag) · [Decisions](https://flutteredge.ai/docs/decisions) · [Speech](https://flutteredge.ai/docs/speech) · [Agent skills](https://flutteredge.ai/docs/agent)
- [Built-in AI](https://flutteredge.ai/docs/builtin-ai) · [ONNX Runtime](https://flutteredge.ai/docs/onnx) · [Genkit](https://flutteredge.ai/docs/genkit) · [Memory diagnostics](https://flutteredge.ai/docs/diagnostics)
- [Desktop](https://flutteredge.ai/docs/desktop) · [Troubleshooting](https://flutteredge.ai/docs/troubleshooting)
- Fine-tune a small model and convert it to `.litertlm` with [litetune](https://litetune.dev) (alpha).

## Teach your AI assistant this package

`flutter_edge_ai` ships agent skills that teach Claude Code, Codex, Cursor and
other coding assistants this API:

```bash
dart run skills@ get --all
```

## Links

- [Migration guide](MIGRATION.md) · [Changelog](CHANGELOG.md) · [Desktop support](DESKTOP_SUPPORT.md)
- [Example app](example/) · [Issues](https://github.com/DenisovAV/flutter_edge_ai/issues) · [Contributing](CONTRIBUTING.md)
