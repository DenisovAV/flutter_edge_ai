# Flutter Edge AI

[![CI Tests](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml)
[![Release Build](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml)
[![pub package](https://img.shields.io/pub/v/flutter_edge_ai.svg)](https://pub.dev/packages/flutter_edge_ai)

On-device AI for Flutter on Android, iOS, Web, macOS, Windows and Linux. Run
Gemma and other open models, or the model the operating system already ships,
with text, vision, audio, function calling, embeddings, RAG and speech — no
server, no cloud. The core is small: you add only the runtimes and stores your
app uses.

<p align="center">
  <img src="https://flutteredge.ai/images/readme-banner.png" alt="Flutter Edge AI — on-device LLMs in your Flutter app">
</p>

> **Formerly `flutter_gemma`.** Through 1.11.3 this package shipped as
> `flutter_gemma`. Version 2.0 also moves RAG out of core into
> `flutter_edge_ai_rag`. See the [migration guide](MIGRATION.md).

📖 Full documentation: **[flutteredge.ai](https://flutteredge.ai)**

## Features

- **Pluggable engines:** LiteRT-LM (`.litertlm`), MediaPipe (`.task`), ONNX Runtime, and the OS's own models (Gemini Nano, Apple Foundation Models, Windows AI Foundry, Chrome Prompt API).
- **Multimodal:** image and audio input with Gemma 4, Gemma 3n and other vision models.
- **Function calling** and **thinking mode** on the models that support them.
- **CPU, GPU and NPU** backends — Qualcomm NPU on Android (opt-in), Intel NPU on Windows.
- **Embeddings and on-device RAG** with Qdrant Edge or SQLite + `sqlite-vec`, payload filters included.
- **Speech:** on-device STT, TTS and a push-to-talk voice loop.
- **Agent skills:** `SKILL.md` tools the model invokes through function calling.
- **Model management:** installs from the network, assets, bundled files or local paths; Hugging Face installs in one call; retries, typed download errors, LoRA weights.
- **Genkit** integration for on-device and hybrid cloud flows.

## Packages

Core registers no engine. Add `flutter_edge_ai` plus what your app needs:

| You want to… | Add |
|---|---|
| Run `.litertlm` models (Gemma 4, Qwen3, FastVLM; all desktop) and LiteRT embeddings | [`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm) |
| Run `.task` / `.bin` models (MediaPipe; mobile and web) | [`flutter_edge_ai_mediapipe`](https://pub.dev/packages/flutter_edge_ai_mediapipe) |
| Run ONNX models — text generation and embeddings | [`flutter_edge_ai_onnx`](https://pub.dev/packages/flutter_edge_ai_onnx) |
| Use the model built into the OS or browser | [`flutter_edge_ai_builtin_ai`](https://pub.dev/packages/flutter_edge_ai_builtin_ai) |
| Tokenizers for text embeddings (needed with the LiteRT or ONNX embedding backend) | [`flutter_edge_ai_embeddings`](https://pub.dev/packages/flutter_edge_ai_embeddings) |
| On-device RAG | [`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag) + [`flutter_edge_ai_qdrant`](https://pub.dev/packages/flutter_edge_ai_qdrant) (native) or [`flutter_edge_ai_sqlite`](https://pub.dev/packages/flutter_edge_ai_sqlite) (all six platforms) |
| Speech-to-text, text-to-speech, voice loop | [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech) |
| Agent skills over function calling | [`flutter_edge_ai_agent`](https://pub.dev/packages/flutter_edge_ai_agent) |
| Memory a model costs, read from the OS | [`flutter_edge_ai_diagnostics`](https://pub.dev/packages/flutter_edge_ai_diagnostics) |
| Genkit, and on-device/cloud routing | [`genkit_flutter_edge_ai`](https://pub.dev/packages/genkit_flutter_edge_ai), [`genkit_hybrid`](https://pub.dev/packages/genkit_hybrid) |

## Supported platforms

| Engine | Android | iOS | Web | macOS | Windows | Linux |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| LiteRT-LM (`.litertlm`) | ✅ | ✅ | ⚠️ preview ¹ | ✅ | ✅ | ✅ |
| MediaPipe (`.task`) | ✅ | ✅ | ✅ | — | — | — |
| ONNX Runtime | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Built-in AI | ✅ | ✅ | ✅ | ✅ | ✅ | — |

¹ Web `.litertlm` is text and function calling only — no vision, audio or LoRA.

LiteRT-LM ships `arm64` on Android, iOS and macOS, `x86_64` on Windows and `x86_64` / `arm64`
on Linux; on Android, MediaPipe `.task` also runs on `x86_64` / `armeabi-v7a`, and on Linux
ONNX is `x86_64` only. Details, GPU backends and per-feature limits:
[installation](https://flutteredge.ai/docs/installation#platform--architecture-support).

## Installation

```yaml
dependencies:
  flutter_edge_ai: ^2.1.2
  flutter_edge_ai_litertlm: ^1.11.3   # or any other engine from the table
```

Then complete the platform setup below.

## Platform setup

### iOS

Set the deployment target to **15.0** (**16.0** if you use
`flutter_edge_ai_mediapipe`) and link pods statically in `ios/Podfile`:

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
your app's `web/` and load them in `index.html`, then add the script for each
engine you use. For MediaPipe:

```html
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

The LiteRT-LM, ONNX, web embeddings and SQLite snippets are in the
[web setup guide](https://flutteredge.ai/docs/installation#web). MediaPipe and
LiteRT-LM run on WebGPU; ONNX also runs on CPU (WASM).

### macOS

macOS needs a build step that stages the LiteRT-LM companion libraries into
the app ([why](https://flutteredge.ai/docs/desktop)), and it runs from a
CocoaPods Podfile. Flutter 3.44+ uses Swift Package Manager by default, so a new
app has no `macos/Podfile`: turn SPM off for the app in `pubspec.yaml`:

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

Run `flutter pub get` (it writes `macos/Podfile`), then replace that Podfile's
`post_install` block with the one below; the next build runs `pod install`
itself. A green build proves nothing: without the block the first model load
fails with `Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib`. If your app already has a `macos/Podfile` (another plugin
needs CocoaPods), keep SPM on and just paste the block. Prefer the pubspec
setting to `flutter config --no-enable-swift-package-manager`, which changes
only your machine — not your teammates' or CI.

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
  # flutter_gemma_litertlm and is delivered next to the dylibs it stages. That
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
          echo "  flutter_gemma_litertlm 1.6.2+ installs it there from its build hook." >&2
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

Add to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

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

Once per device; installed models survive restarts.

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

## Three things that fail quietly

- **`maxTokens` is the context window**, not the reply length: prompt, history
  and answer together. `.litertlm` needs at least 1024. Cap the reply with
  `createChat(maxOutputTokens: …)` (`.litertlm`; MediaPipe ignores it).
- **`Message.isUser` defaults to `false`.** A user message without
  `isUser: true` gets an empty answer.
- **`fileType` picks the engine**, not the file name. `installModel` defaults
  to `ModelFileType.task`, so a `.litertlm` must say `ModelFileType.litertlm`.

## Supported models

| Model | `ModelType` | Function calling | Thinking | Vision / audio |
|---|---|:---:|:---:|:---:|
| Gemma 4 E2B / E4B ² | `gemma4` | ✅ | ✅ | ✅ / ✅ |
| Gemma 3n E2B / E4B ² | `gemmaIt` | ✅ ¹ | — | ✅ / ✅ |
| Gemma 3 1B, Gemma 3 270M | `gemmaIt` | — | — | — |
| FunctionGemma 270M | `functionGemma` | ✅ | — | — |
| Qwen3 0.6B | `qwen3` | ✅ | ✅ | — |
| Qwen3.5 / 3.6 / 3.8 | `qwen35` | — | — | — |
| Qwen 2.5 0.5B / 1.5B | `qwen` | ✅ | — | — |
| DeepSeek R1 | `deepSeek` | ✅ | ✅ | — |
| Phi-4 Mini | `phi` | ✅ | — | — |
| FastVLM, Qwen2-VL, SmolVLM2, LLaVA-OneVision | `general` | — | — | ✅ / — |
| SmolLM, SmolLM3, LFM2.5, Phi-4 Mini Reasoning | `general` | — | — | — |

¹ The downloadable E4B `.litertlm`.

² On Web: no audio input; Gemma 3n vision is native-only; Gemma 4 thinking needs the `.litertlm` web build.

Download links, sizes, formats per platform, embedding and speech models:
[models](https://flutteredge.ai/docs/models).

## Going further

- [Getting started](https://flutteredge.ai/docs/getting-started) — sessions, system instructions, removing models
- [Models](https://flutteredge.ai/docs/models) — model sources, Hugging Face installs
- [Function calling](https://flutteredge.ai/docs/function-calling) · [Multimodal](https://flutteredge.ai/docs/multimodal) · [Thinking mode](https://flutteredge.ai/docs/thinking-mode)
- [Embeddings & RAG](https://flutteredge.ai/docs/embeddings-and-rag) · [Speech](https://flutteredge.ai/docs/speech) · [Agent skills](https://flutteredge.ai/docs/agent)
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
