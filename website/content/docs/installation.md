---
title: Installation
description: Add the packages, register engines, and complete per-platform setup for iOS, Android, Web, and Desktop.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Flutter Edge AI is a small **core** package plus **opt-in** packages for each
engine / backend (split since 1.0, then `flutter_gemma`), so your app only pulls
the native weight it actually uses. Add the core package, then the packages for the model
formats and features you need.

## 1. Add packages to `pubspec.yaml`

```
dependencies:
  flutter_edge_ai: latest_version              # Core — always required (no engine on its own)

  # Inference engines — add at least one:
  flutter_edge_ai_litertlm: latest_version     # .litertlm models (FFI; mobile + desktop + web) + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: latest_version    # .task / .bin models (MediaPipe; mobile + web)
  flutter_edge_ai_builtin_ai: latest_version   # OS system models — Gemini Nano (Android) / Apple FM (iOS 26+/macOS 26+) / Windows AI Foundry / Chrome Prompt API (Web)
  flutter_edge_ai_onnx: latest_version         # ONNX models — ORT-GenAI (FFI, native) / Transformers.js (web) + OnnxEmbeddingBackend

  # Optional — text-embedding tokenizer implementations:
  flutter_edge_ai_embeddings: latest_version   # embedding tokenizer implementations (Gemma SentencePiece, BERT WordPiece), registered via embeddingTokenizers: (needs a backend, e.g. LiteRtEmbeddingBackend above)

  # Optional — independent RAG orchestration plus one storage provider:
  flutter_edge_ai_rag: latest_version       # RagIndex, profiles, filters
  flutter_edge_ai_qdrant: latest_version    # qdrant-edge; fastest on native
  flutter_edge_ai_sqlite: latest_version    # sqlite-vec / vec0; all platforms incl. web — needs Flutter 3.47

  # Optional — on-device speech (STT + TTS):
  flutter_edge_ai_speech: latest_version       # transcribe audio + synthesize speech (on-device STT + TTS; native only) + voice loop

  # Optional — on-device agent skills:
  flutter_edge_ai_agent: latest_version        # agent skills the model runs itself (text / JS / native-intent / MCP)

  # Optional — memory diagnostics (Android + iOS):
  flutter_edge_ai_diagnostics: latest_version  # what a model costs in memory the OS cannot reclaim, read from the OS
```

**Pick by need:**

| You want to… | Add |
|---|---|
| Run `.litertlm` models (Gemma 4, Qwen3, FastVLM, + all desktop) | `flutter_edge_ai_litertlm` |
| Run `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4) | `flutter_edge_ai_mediapipe` |
| Run the OS system model with no download (Gemini Nano / Apple FM / Windows AI Foundry) | `flutter_edge_ai_builtin_ai` |
| Run ONNX models — ORT-GenAI (native) or Transformers.js (Web) | `flutter_edge_ai_onnx` |
| Generate text embeddings | `flutter_edge_ai_embeddings` + `flutter_edge_ai_litertlm` (`LiteRtEmbeddingBackend`) |
| Generate text embeddings from ONNX/ORT models | `flutter_edge_ai_embeddings` + `flutter_edge_ai_onnx` (`OnnxEmbeddingBackend`) |
| On-device RAG on native, fastest (Android/iOS/desktop) | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| On-device RAG on web, or a portable/exact store on any platform | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` (Flutter 3.47+) |
| Transcribe audio, synthesize speech, or run a voice loop on-device (STT + TTS + voice) | `flutter_edge_ai_speech` |
| Run on-device agent skills the model executes itself (text / JS / native-intent / MCP) | `flutter_edge_ai_agent` |
| Measure what a model costs in memory the OS cannot reclaim (Android + iOS) | [`flutter_edge_ai_diagnostics`](/docs/diagnostics) |

Core registers **no** AI runtime by itself — wire inference, embedding, and
speech packages in `FlutterEdgeAi.initialize(...)` below. RAG is independent:
construct `FlutterEdgeAiRag` with a storage provider. Run `flutter pub get` to
install.

<Info>

**Migrating from `flutter_gemma` or Flutter Edge AI 1.x?** See the
[Migration guide](/docs/migration). Version 2.0 moves RAG out of core and adds
durable embedding profiles.

</Info>

## 2. Initialize Flutter Edge AI

Call `await FlutterEdgeAi.initialize(...)` once in `main()` and **register the opt-in
packages you added** to `pubspec.yaml`. Core registers no engine on its own, so
without this step `getActiveModel()` / `getActiveEmbedder()` throw a clear
"add the engine package" error.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    // Inference engines — add the ones whose packages you depend on:
    inferenceEngines: const [
      LiteRtLmEngine(),     // flutter_edge_ai_litertlm  — .litertlm models
      MediaPipeEngine(),    // flutter_edge_ai_mediapipe — .task / .bin models
      BuiltInAiEngine(),    // flutter_edge_ai_builtin_ai — Gemini Nano / Apple FM
    ],
    // Optional — embeddings (also usable by an independent RAG index):
    embeddingBackends: const [
      LiteRtEmbeddingBackend(), // flutter_edge_ai_litertlm
    ],
    // The tokenizer is registered separately — which family a model needs is a
    // property of the model, not of the engine that runs it.
    embeddingTokenizers: const [
      GemmaEmbeddingTokenizers(), // flutter_edge_ai_embeddings
    ],
    // Optional — on-device speech-to-text:
    sttBackends: const [
      LiteRtSttBackend(), // flutter_edge_ai_speech
    ],
    // Optional — on-device text-to-speech:
    ttsBackends: const [
      LiteRtTtsBackend(), // flutter_edge_ai_speech
    ],
    // Common settings:
    // String.fromEnvironment yields '' when the define is absent, and an
    // empty token still sends a bare `Authorization: Bearer` header. Pass
    // null instead so the request goes out unauthenticated.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
    maxDownloadRetries: 10,
  );

  runApp(MyApp());
}
```

**Which parameter ← which package:**

| Parameter | Provided by | Notes |
|---|---|---|
| `inferenceEngines: [LiteRtLmEngine()]` | `flutter_edge_ai_litertlm` | `.litertlm` (mobile + desktop + web) |
| `inferenceEngines: [MediaPipeEngine()]` | `flutter_edge_ai_mediapipe` | `.task` / `.bin` (mobile + web) |
| `inferenceEngines: [OnnxEngine()]` | `flutter_edge_ai_onnx` | ONNX models — ORT-GenAI (FFI: macOS arm64, Linux x64, Windows x64, Android arm64, iOS arm64) or Transformers.js (Web) |
| `embeddingBackends: [LiteRtEmbeddingBackend()]` | `flutter_edge_ai_litertlm` | text embeddings |
| `embeddingBackends: [OnnxEmbeddingBackend()]` | `flutter_edge_ai_onnx` | text embeddings from ONNX/ORT models |
| `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` | `flutter_edge_ai_embeddings` | required by BOTH embedding backends above |
| `sttBackends: [LiteRtSttBackend()]` | `flutter_edge_ai_speech` | speech-to-text (native only) |
| `ttsBackends: [LiteRtTtsBackend()]` | `flutter_edge_ai_speech` | text-to-speech (native only) |

Add only the runtimes you ship. Passing both `LiteRtLmEngine()` and
`MediaPipeEngine()` lets one app run both formats — the registry routes each
model to the engine that handles its file type. For RAG, register
`SqliteVectorStoreProvider()` or `QdrantVectorStoreProvider()` on a separate
`FlutterEdgeAiRag` instance; see [Embeddings & RAG](/docs/embeddings-and-rag).

**Common settings:**

- `huggingFaceToken`: authentication token for gated models (Gemma3n, Gemma 3 1B / 270M, EmbeddingGemma).
- `maxDownloadRetries`: number of retry attempts for failed downloads (default: 10).
- `webStorageMode` **(Web only)**: storage strategy for model files (default: `cacheApi`).
  - `WebStorageMode.cacheApi`: Cache API with Blob URLs (for models <2GB).
  - `WebStorageMode.streaming`: OPFS streaming (for large models >2GB like E4B, 7B).
  - `WebStorageMode.none`: no caching (ephemeral mode for testing).

<Info>

Use `WebStorageMode.streaming` when shipping `.litertlm` web models — the
`@litert-lm/core` engine consumes an OPFS ReadableStream and avoids Chrome's
~2 GB blob-fetch limit on Gemma 4 E2B/E4B web builds.

</Info>

## 3. Platform-specific setup

<Warning>

Complete platform-specific setup before running a model.

</Warning>

### iOS

Required by any engine package: `flutter_edge_ai_litertlm`, `flutter_edge_ai_mediapipe`,
`flutter_edge_ai_onnx`, `flutter_edge_ai_builtin_ai` and/or `flutter_edge_ai_speech`.

**Set the minimum iOS version to 15.0** — or **16.0** if your app depends on
`flutter_edge_ai_mediapipe`, which needs MediaPipe GenAI. Core, `flutter_edge_ai_litertlm`
and embeddings build from 15.0. (`flutter_gemma` before 1.6.4 declared
16.0.)

`flutter_edge_ai_builtin_ai` no longer sets an Apple floor of its own — since 0.3.0
its native layer is `flutter_local_ai`, which builds from **iOS 13.0 / macOS
12.0**. On iOS that changes nothing (core's 15.0 still wins); on **macOS it
raises the floor from 10.15 to 12.0**, and a lower deployment target fails
resolution with a message naming the `flutter_local_ai` pod rather than the
package you added.

**Where you set it depends on the dependency manager.** Swift Package Manager is the
default since Flutter 3.44 (opt-in before that), and an SPM-only app has no `Podfile` at all.
Flutter 3.47+ creates (and migrates) apps at iOS 15.0; on 3.44.x the template is 13.0 — set **iOS
Deployment Target** on the Runner target in Xcode, or the build fails with `requires
minimum platform version 15.0 … but this target supports 13.0`. iOS needs no Podfile
step; macOS does — see [Desktop → macOS](/docs/desktop#macos).
`flutter_edge_ai_mediapipe` ships no `Package.swift`, so an app using it also gets a
`Podfile`; set the platform there as well:

```
platform :ios, '16.0'   # 15.0 if the app does not use flutter_edge_ai_mediapipe
```

Declare `platform` only once — CocoaPods rejects a second one with
`Invalid Podfile file: The target 'Pods' already has a platform set`.

**Change the linking type** of pods to static in `Podfile`:

```
use_frameworks! :linkage => :static
```

**Enable file sharing** in `Info.plist`:

```
<key>UIFileSharingEnabled</key>
<true/>
```

**Add a network access description** in `Info.plist` (for development):

```
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires local network access for model inference services.</string>
```

**Enable performance optimization** in `Info.plist` (optional):

```
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

**Add memory entitlements** in `Runner.entitlements` (for large models):

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
	<true/>
</dict>
</plist>
```

<Info>

No host-side `Podfile` `post_install` is required on iOS — flutter_edge_ai patches
the upstream LiteRT-LM `dlopen` path to use
`@executable_path/Frameworks/<X>.framework/<X>` so dyld resolves Metal
accelerators directly through the Native-Assets-bundled framework. This also
keeps `Runner.app/Frameworks/` App-Store-clean (fixes ITMS-90432).

</Info>

### Android

Release builds need `<uses-permission android:name="android.permission.INTERNET"/>`
in `android/app/src/main/AndroidManifest.xml` to download models (Flutter's
template adds it only to the debug and profile manifests).

**Add-to-app hosts must declare the Kotlin Gradle Plugin themselves.** Flutter
auto-applies KGP to plugin modules only when the host provides it, so a Java-only native
host fails with `Could not find method kotlin()`. Add KGP to the host's root
`buildscript`/`plugins {}`. A normal `flutter build` app needs nothing — Flutter's own
Gradle plugin carries KGP.

**GPU and NPU (any engine): nothing to add to the manifest.** `flutter_edge_ai`'s
own manifest declares the OpenCL and FastRPC namespace entries and the manifest
merger folds them into your app. These
are what your merged manifest must contain if you pin or audit it — note
`libvndksupport.so`: without it the OpenCL ICD load is denied on Android 12+, the
engine falls back to WebGPU, and some Mali drivers hard-freeze (#324).

```
<uses-native-library android:name="libvndksupport.so" android:required="false"/>
<uses-native-library android:name="libOpenCL.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-car.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-pixel.so" android:required="false"/>
<uses-native-library android:name="libcdsprpc.so" android:required="false"/>
```

**Qualcomm NPU (opt-in).** `PreferredBackend.npu` needs Qualcomm's QNN runtime,
which Qualcomm licenses for redistribution only inside an application, so the
app asks for it in its `pubspec.yaml` (the workspace root's, if the app is a pub
workspace member):

```
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

The build hook then fetches the runtime — from Maven Central for Android, from
Qualcomm's QAIRT SDK for Linux arm64 boards. Without the flag `npu` falls back
to GPU, then CPU. See [LiteRT-LM](/docs/litertlm).

**ProGuard/R8 (only if you use `flutter_edge_ai_mediapipe`):** the package ships
its own consumer ProGuard rules; from 1.0.6 a release build needs no rules in
your app (built on AGP 9.1). On 1.0.5 and earlier R8 fails the release build
with `Missing class` (seen on AGP 9) — upgrade to 1.0.6, or add to your
`proguard-rules.pro`:

```
-dontwarn com.google.auto.value.**
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
```

If a release build then fails at run time with `UnsatisfiedLinkError` or a
missing MediaPipe class, also add:

```
# MediaPipe
-keep class com.google.mediapipe.** { *; }

# Protocol Buffers
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
```

<Info>

`flutter_edge_ai_litertlm` is delivered as a Native-Assets dylib (no MediaPipe Java
classes), so it needs no ProGuard rules.

</Info>

<Info>

**`flutter_edge_ai_builtin_ai`** brings in `flutter_local_ai`, which declares
`minSdk 26` (the ML Kit GenAI / AICore floor) — raise your app's `minSdk` to 26
or the manifest merger fails. The ML Kit Prompt API `beta4` artifact carries
Kotlin 2.3 metadata, so the app also needs **Kotlin 2.3.21**. Unlike
flutter_edge_ai's own plugins it applies KGP itself, so `android.builtInKotlin=true`
is not usable in an app that depends on it.

</Info>

#### Android architecture support

MediaPipe text inference (`.task` / `.bin`) works on `arm64-v8a`, `x86_64`, and
`armeabi-v7a`. Everything backed by `libLiteRtLm` (`.litertlm` inference,
including its vision and audio input, embedding via LiteRT FFI, speech) is
**`arm64-v8a` only**:

| Android feature | arm64-v8a | x86_64 | armeabi-v7a |
|---|:---:|:---:|:---:|
| Text inference (`.task` / `.bin`) | ✅ | ✅ | ✅ |
| `.litertlm` (FFI) | ✅ | ❌ | ❌ |
| Embedding (LiteRT FFI) | ✅ | ❌ | ❌ |
| Speech STT + TTS (LiteRT FFI) | ✅ | ❌ | ❌ |

If your app uses only the arm64-only features, restrict the build to arm64 so the
Play Store does not offer broken APKs to incompatible devices:

```
android {
    defaultConfig {
        ndk { abiFilters 'arm64-v8a' }
    }
}
```

In a Kotlin build script (`build.gradle.kts`):

```
android {
    defaultConfig {
        ndk { abiFilters += listOf("arm64-v8a") }
    }
}
```

<Warning>

Anything backed by `libLiteRtLm.so` on Android — `.litertlm` inference,
embeddings, and speech (STT + TTS) — requires **minSdk 30**: the library depends on
API 30+ Bionic syscalls (`pthread_cond_clockwait`, `sem_clockwait`) that cannot
be shimmed on older devices. MediaPipe `.task` models work on lower API levels.

</Warning>

### Web

On web, MediaPipe ignores `preferredBackend` and always runs on the GPU
(WebGPU); ONNX honours `PreferredBackend.cpu` by pinning WASM.

**Every web app** needs flutter_edge_ai's model storage helpers. Copy `cache_api.js`
and `opfs_helper.js` from the `flutter_edge_ai` package's `web/` directory into
your app's `web/` (find the package directory with
`grep -A1 '"name": "flutter_edge_ai"' .dart_tool/package_config.json`), then load
them in `web/index.html`:

```
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
```

Then add the CDN script(s) for the **engine package(s) you use**.

**`flutter_edge_ai_mediapipe`** (`.task` / `-web.task` models):

```
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

**`flutter_edge_ai_litertlm`** (`.litertlm` web models — early preview). The
`@litert-lm/core` ESM doesn't assign window globals and module scripts are
deferred, so Dart must await `window.litertLmReady` before any static interop:

```
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
  return m.Engine;
})();
</script>
```

**`flutter_edge_ai_onnx`** (ONNX models on Web): generation runs on
[Transformers.js](https://huggingface.co/docs/transformers.js) v4, embeddings
on onnxruntime-web. Both are readiness-handshake shims, same shape as the
`litertLmReady` promise above:

```
<script type="module">
window.transformersReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.0');
  window.transformers = m;
  return m;
})();
</script>

<script type="module">
window.ortReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/ort.bundle.min.mjs');
  m.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/';
  window.ort = m;
  return m;
})();
</script>
```

Only add the shim(s) for the arm(s) you use — `transformersReady` for
`OnnxEngine`, `ortReady` for `OnnxEmbeddingBackend`.

**`LiteRtEmbeddingBackend`** (web embeddings, `flutter_edge_ai_litertlm`): runs on
LiteRT.js, which needs the four files in `flutter_edge_ai_litertlm`'s `web/`
copied into your app's `web/`: `litert_embeddings.js`, `sentencepiece.js`,
`litert.js` and `tensorflow.js`. The first imports the other three by relative
path — they are one bundle in four pieces — so they sit together and the entry
module is loaded locally:

```
<script type="module" src="litert_embeddings.js"></script>
```

The WASM runtime underneath comes from a pinned CDN copy by default
(`flutter_edge_ai_litertlm`) — nothing else to install. To serve it
yourself, copy `node_modules/@litertjs/core/wasm/` into `web/wasm/` and set
`LiteRtWebRuntime.wasmPath = '/wasm/';` before the first embedding. See
[`flutter_edge_ai_litertlm`'s embeddings on web](https://pub.dev/packages/flutter_edge_ai_litertlm#embeddings-on-web).

**`flutter_edge_ai_sqlite`** (web RAG): no `<script>`. Copy the package's
`web/rag/sqlite3.wasm` (a `sqlite3.wasm` with `sqlite-vec` statically linked)
into your app's web root as `rag/sqlite3.wasm`, and serve the app with the
cross-origin isolation headers OPFS persistence needs:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

<Info>

**Model compatibility:** mobile `.task` models often don't work on web — use the
`-web.task` (MediaPipe) or `.litertlm` (LiteRT-LM) web variant. Check the model
repo for web-compatible builds.

</Info>

### Desktop (macOS, Windows, Linux)

Desktop is served **primarily** by **`flutter_edge_ai_litertlm`** (`.litertlm`
files) — the default engine, whose native library is fetched at build time by the
package's Native-Assets hook (no manual download/bundling). **`flutter_edge_ai_onnx`**
([ONNX Runtime](/docs/onnx)) also runs on all three desktop OSes
(macOS/Windows/Linux), and the OS built-in model is available via
**`flutter_edge_ai_builtin_ai`** on **macOS** ([Apple Foundation
Models](/docs/builtin-ai)) and on **Windows** ([AI Foundry](/docs/builtin-ai) —
nothing to configure to build: `flutter_local_ai` resolves the Windows App SDK
projection itself; running needs Windows 11 25H2+ on Copilot+-class hardware and
a packaged app); not on Linux. What
holds across all of desktop: there is no MediaPipe engine on desktop — `.task` /
`.bin` models are **NOT compatible** with desktop.

**macOS needs one extra step:** turn Swift Package Manager off for the app
(`flutter: config: enable-swift-package-manager: false` in `pubspec.yaml`) and
paste a `post_install` block into the generated `macos/Podfile` — see
[Desktop → macOS](/docs/desktop#macos). Without it the build succeeds and the
first model load fails.

See [Desktop Support](/docs/desktop) for the full per-platform reference (macOS
`Podfile` `post_install`, entitlements, Windows DLL loading — no VC++
redistributable needed — Linux Vulkan driver, and known limitations).

## Platform & architecture support

The native packages ship prebuilts only for the architectures below. Other ABIs
fail at native load with a typed error.

| Platform | Supported architecture | Not supported |
|---|---|---|
| Android | `arm64-v8a` (full) | `armeabi-v7a`, `x86_64` ¹ |
| iOS device | `arm64` | — |
| iOS Simulator | `arm64` (Apple Silicon Mac) | `x86_64` (Intel Mac) |
| macOS | `arm64` (Apple Silicon) | `x86_64` (Intel Mac) |
| Linux | `x86_64`, `arm64` | — |
| Windows | `x86_64` | `arm64` |

¹ MediaPipe text inference also works on Android `x86_64` / `armeabi-v7a` (see
the Android section above).

For development, prefer an Apple Silicon Mac — the Android emulator runs
`arm64-v8a` natively, and macOS / iOS Simulator builds are arm64.

## HuggingFace authentication

Many models require authentication to download from HuggingFace. **Never commit
tokens to version control.**

### Recommended: `config.json` pattern

Create a config template `config.json.example`:

```
{
  "HUGGINGFACE_TOKEN": ""
}
```

Copy it and add your token from
[huggingface.co/settings/tokens](https://huggingface.co/settings/tokens):

```
cp config.json.example config.json
```

Add `config.json` to `.gitignore`, then run with the config:

```
flutter run --dart-define-from-file=config.json
```

Access it in code:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const token = String.fromEnvironment('HUGGINGFACE_TOKEN');

  await FlutterEdgeAi.initialize(
    huggingFaceToken: token.isNotEmpty ? token : null,
    // plus inferenceEngines / embeddingBackends from step 2
  );

  runApp(MyApp());
}
```

### Which models require authentication?

**Gated (auth required):** Gemma3n (E2B, E4B), Gemma 3 1B, Gemma 3 270M,
EmbeddingGemma.

**Public (no auth):** Gemma 4 (the litert-community builds), DeepSeek, Qwen3,
Qwen 2.5, SmolLM, LFM2.5, Phi-4, FastVLM.

To use a gated repo: visit the model page → "Request Access" button.

## Logging

Flutter Edge AI's internal logs are **silent in release builds** — model output,
prompts, and conversation history are never written to logcat / syslog. In debug
builds they're shown according to `FlutterEdgeAi.logLevel`:

| Level | What it prints (debug only) |
|---|---|
| `EdgeAiLogLevel.none` | Nothing — fully silent. |
| `EdgeAiLogLevel.info` *(default)* | Lifecycle, errors, diagnostics. **No** model output / prompts. |
| `EdgeAiLogLevel.verbose` | Everything above **plus** model output, prompts, and conversation history. |

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// See the model's generated tokens and prompts while debugging:
FlutterEdgeAi.logLevel = EdgeAiLogLevel.verbose;

// Or silence logging entirely:
FlutterEdgeAi.logLevel = EdgeAiLogLevel.none;
```

Release builds are always silent regardless of this setting. The level is
process-global and per-isolate; set it once at startup.
