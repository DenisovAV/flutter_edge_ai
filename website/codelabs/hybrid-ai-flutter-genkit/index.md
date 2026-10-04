author: Sasha Denisov
summary: Hybrid AI in Flutter with Genkit Dart — From Cloud to On-Device
id: hybrid-ai-flutter-genkit
categories: flutter, ai, gemma, genkit
environments: android, ios, macos, windows, linux, web
status: Published

# Hybrid AI in Flutter: From Cloud to On-Device with Genkit Dart

## Overview
Duration: 7

### What you'll build

**An offline travel guide.** You are abroad, roaming is expensive or missing
entirely, and you still want to ask "what should I see in Prague?" That is the
reason this app is hybrid rather than one more chat with Gemini — the phone has
to be able to answer on its own.

It is a single screen: a chat that streams its replies. Everything else on that
screen exists to make *where the answer came from* visible.

- A **policy picker** — Cloud, Local, Smart (image-aware), Cascade (escalate on
  quality), Budget (cost-gated). The conversation and its history never change;
  only the brain behind them does.
- A **RAG toggle**. Off, the model answers from memory. On, your question is
  embedded **on the phone** and matched against ten city guides shipped inside
  the app — Paris, Tokyo, Barcelona, Istanbul, Marrakech, New York, Prague,
  Rio, Singapore, Sydney. A `Sources: Paris` line under the reply is the only
  place you can see that the answer was grounded in a guide rather than
  invented.
- **Image attachment** — a photo goes to the cloud, the only branch that
  declares vision; on the text-only policies the send is blocked with a hint.
- A **budget counter** that spends three cloud calls, then quietly drops to the
  device.

### The finished app in 30 seconds

When you reach the end, this is the demo — worth reading now, so you know what
you are building toward:

1. On **Cloud**, ask "what should I see in Paris?" — an ordinary cloud answer,
   tokens streaming in.
2. Turn **RAG** on and ask the same question: a `Sources: Paris` line appears,
   and the answer now leans on the bundled guide instead of the model's memory.
3. Switch to **Local** and turn off wi-fi. The phone answers. This is the moment
   the whole codelab exists for.
4. Attach a photo while still on **Local** — the send is blocked with a hint.
   Switch to **Smart** and the same photo goes to the cloud.
5. Select **Budget** and send four messages: on the fourth the counter reaches
   its cap of three and the answer quietly arrives from the device.

### How we get there

Six increments, each a directory you can open and run:

1. **Cloud Chat** — Streaming responses from Gemini via `genkit_google_genai`
2. **Local Inference** — On-device AI with Gemma 3 1B via `genkit_flutter_edge_ai`
3. **Hybrid Strategy** — Cloud/local routing via `genkit_hybrid` (fallback, capability, cascade, budget)
4. **Smart Routing & Images** — multimodal input and image-aware policy routing
5. **Embeddings** — Semantic vector representations with EmbeddingGemma via Genkit
6. **RAG** — Context-augmented generation using a local tourist guide

### What you'll learn

- How to use the Genkit Dart framework for AI inference in Flutter
- How to route between cloud and on-device models using a single `Genkit`
  instance and `genkit_hybrid`'s routing strategies
- How to run AI models locally on device with `genkit_flutter_edge_ai`
- How to send images to a vision-capable model and gate routing on model
  capabilities
- How text embeddings work and how to build a RAG pipeline with Genkit

### What you'll need

- Flutter 3.44 or newer
- A GEMINI_API_KEY from [aistudio.google.com](https://aistudio.google.com)
- A HuggingFace account (for model downloads)
- Any one of Flutter's six platforms: an arm64 Android device or emulator
  (libLiteRtLm is arm64-only — an Apple-silicon Mac's emulator qualifies), an
  iOS device or simulator, an Apple-silicon Mac, a Windows or Linux desktop, or
  Chrome. The same code runs on all of them through Step 4 — Step 3 lists the
  handful of things each one asks of you — including Step 5's embeddings and
  the RAG Step 6 builds on them, which run on Chrome too
- ~1 GB free disk space for the on-device LLM plus EmbeddingGemma on native;
  on web the LLM alone is a 2.0 GB build (Step 3 explains why it's a
  different, larger model there), plus EmbeddingGemma on top

### Architecture

```
┌──────────────────────────────────────────┐
│              Flutter App                 │
├──────────────────────────────────────────┤
│                AiEngine                  │
│          one Genkit, two plugins         │
├──────────────────┬───────────────────────┤
│  googleAI plugin │  GenkitFlutterEdgeAi   │
│  gemini-3.7-flash│  Gemma 3 1B +         │
│     (kCloud)     │  EmbeddingGemma       │
│                  │    (kOnDevice)        │
└──────────────────┴───────────────────────┘
```

On the web, `kOnDevice` is a different, larger model — Gemma 3 1B has no
browser build, so `AiEngine` installs Gemma 4 E2B's web export instead. Step 3
covers why. EmbeddingGemma is part of that plugin only off web — Step 5
explains why on-device embeddings, and the RAG built on them, don't run in a
browser yet.

`genkit_hybrid` composes both branches into one routable `Model` —
`hybridModel()` / `cascadeModel()` — selected by a `PolicyMode`: cloud, local,
smart, cascade, budget.

The key insight: `AiEngine` builds a single `Genkit` instance with both
plugins registered, resolves the cloud and on-device models once, and hands
them to `genkit_hybrid` as a `Map<String, Model>` of branches. For each
`PolicyMode` it composes one branch map into an ordinary Genkit `Model` and
registers it on `ai.registry` — once, during `initialize()`. `engine.modelFor(policy)`
just returns that already-registered `Model`. The chat screen always calls
the same
`ai.generateStream(model: engine.modelFor(policy), messages: [...])`; only
which `Model` `modelFor` returns changes with the policy.

## Step 1: Starter Project
Duration: 5

### Get the code

Every step of this codelab exists as a complete, runnable app, so you can join
at any point or check your work against the next one.

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/hybrid-ai-flutter-genkit
ls
```

```text
step_00_starter/         the shell you start from
step_01_cloud_ai/        after Step 2 — Gemini, streaming
step_02_local_ai/        after Step 3 — Gemma 3 1B on the device
step_03_hybrid/          after Step 4 — one AiEngine, two branches
step_04_smart_routing/   after Step 4.5 — images and the routing policies
step_05_embeddings/      after Step 5 — on-device embeddings
complete/                after Step 6 — the finished app, with RAG
```

### Explore the project

Open `step_00_starter` in your IDE and run `flutter pub get`. The starter
includes:

- **`lib/main.dart`** — Simple app entry point, no async setup needed
- **`lib/screens/chat_screen.dart`** — Chat UI with TextField, ListView, send button
- **`lib/widgets/message_bubble.dart`** — Styled message bubbles (user right, AI left)
- **`lib/models/message_model.dart`** — Simple `ChatMessage` data class
- **`lib/services/ai_service.dart`** — Abstract `AIService` interface
- **`assets/tourist_data/`** — 10 JSON files with city descriptions (Paris, Tokyo, New York…)

### The AIService interface

All our AI services implement this contract:

```dart
abstract class AIService {
  Future<void> initialize();
  Stream<String> generateResponseStream(String prompt);
  Future<void> dispose();
}
```

`generateResponseStream` returns a `Stream<String>` — responses stream
token-by-token for a real-time chat feel.

### Run the starter

```bash
cd step_00_starter
flutter run
```

You'll see the chat UI. Messages echo back with a placeholder. Let's replace
that with real AI next.

## Step 2: Cloud Chat with Genkit
Duration: 15

### Get your API key

Go to [aistudio.google.com](https://aistudio.google.com), sign in with your
Google account, and click **Get API key**. Copy the key — you'll use it with
`--dart-define`.

> No Firebase project, no CLI setup — just an API key.

> **Model choice**: this workshop pins `gemini-3.7-flash` — the older
> `gemini-2.5-flash` is being phased out.

### Update dependencies

In `pubspec.yaml`, uncomment the Genkit dependencies:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8

  # Step 2: Cloud AI
  genkit: ^0.16.0
  genkit_google_genai: ^0.3.1
```

Run `flutter pub get`.

### Create CloudAIService

Create `lib/services/cloud_ai_service.dart`:

```dart
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';

import 'ai_service.dart';

// Pass at build time: flutter run --dart-define=GEMINI_API_KEY=AIza...
const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

class CloudAIService implements AIService {
  Genkit? _ai;

  @override
  Future<void> initialize() async {
    if (_apiKey.isEmpty) {
      throw StateError(
        'GEMINI_API_KEY is not set. '
        'Run with --dart-define=GEMINI_API_KEY=your_key',
      );
    }
    _ai = Genkit(plugins: [googleAI(apiKey: _apiKey)]);
  }

  @override
  Stream<String> generateResponseStream(String prompt) async* {
    final ai = _ai;
    if (ai == null) throw StateError('CloudAIService not initialized');

    final stream = ai.generateStream(
      model: googleAI.gemini('gemini-3.7-flash'),
      prompt: prompt,
    );

    await for (final chunk in stream) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  @override
  Future<void> dispose() async {
    _ai = null;
  }
}
```

### Wire it up in chat_screen.dart

Replace the echo stub:

```dart
import '../services/cloud_ai_service.dart';

// in _ChatScreenState:
late final CloudAIService _service;

// in initState:
_service = CloudAIService();
_initService();

// in _initService:
await _service.initialize();

// in _sendMessage:
await for (final chunk in _service.generateResponseStream(text)) {
  buffer.write(chunk);
  // ... the throttled setState loop, then _scrollToBottom()
}
```

### Run with your API key

```bash
flutter run --dart-define=GEMINI_API_KEY=your_key_here
```

Type "Tell me about Paris" — Gemini streams a response token by token.

> **What happened?** `Genkit(plugins: [googleAI(...)])` registered Gemini as a
> model provider. `ai.generateStream(model: googleAI.gemini('gemini-3.7-flash'), ...)`
> streams the response. The `Genkit` instance is the single point of contact
> for all AI operations.

## Step 3: Local Inference with genkit_flutter_edge_ai
Duration: 20

### Platform setup

This is the only step with platform configuration in it, and it is less than
you would expect on any of the six. Read the subsection for the platform you
are running on and skip the others. [Getting Started](/codelabs/getting-started-flutter-gemma)
covers each of them at length in its Step 2; what follows is what *this* app
needs.

**Android** — one line, because both the model download and the Gemini call
are ordinary HTTPS requests (`android/app/src/main/AndroidManifest.xml`):

```xml
    <uses-permission android:name="android.permission.INTERNET" />
```

…and the API floor in `android/app/build.gradle.kts`, because the on-device
half of the app loads `libLiteRtLm.so`:

```kotlin
defaultConfig {
    // …
    // libLiteRtLm.so needs API 30+ Bionic (pthread_cond_clockwait,
    // sem_clockwait). Below 30 the app installs and then fails at the first
    // model load with a dlopen error.
    minSdk = 30
```

**iOS** — a deployment target of 15.0 or newer, and three memory entitlements in
`ios/Runner/Runner.entitlements`:

```xml
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
	<true/>
```

Every step app already ships that file with the Runner target pointed at it, so
there is nothing to wire up here — in your own project you select it in Xcode's
**Signing & Capabilities** editor. The keys lift the per-process memory ceiling
iOS imposes: half a gigabyte of weights plus a KV cache is comfortably over the
default jetsam limit on an older iPhone, and the kill that follows has no
Dart-visible error — the app simply disappears.

**macOS** — two entitlements and one build phase. The entitlements go in
**both** `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`, and every step app from this one on already
carries them:

```xml
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
```

`network.client` is what lets a sandboxed macOS app reach Gemini and Hugging
Face at all. `disable-library-validation` does nothing yet: it matters once
Hardened Runtime is on, which notarizing the app for distribution requires. The
build phase below signs LiteRT-LM and its companion libraries ad hoc, and library
validation refuses code not signed by Apple or by your own team. The iOS keys
above are deliberately **not** here: they are iOS entitlements. On macOS a build
with no signing team fails outright with `"Runner" has entitlements that require
signing with a development certificate`, and a team-signed build silently drops
them. macOS support is Apple Silicon only.

The build phase is the part unique to macOS. Every step app from this one on
ships a `macos/Podfile` whose `post_install` block stages the runtime's
companion libraries into the built `.app`. A macOS build that succeeds proves
nothing here — the app compiles, links, signs and launches without the staging
too, and the failure arrives at the first model load. One trap, measured: with
Swift Package Manager on and no other CocoaPods plugin in the app, Flutter
prints **Removing CocoaPods integration**, the `post_install` block never runs,
and nothing is staged. Either turn SPM off with
`flutter config --no-enable-swift-package-manager`, or keep one CocoaPods
plugin in the app.

**Windows** — nothing in the app, and x86_64 only: there is no Windows arm64
build of the runtime. Nothing needs installing: nothing in the bundle needs a C++
runtime the machine does not already have.

**Linux** — nothing in the app either. glibc 2.34 or newer, which means Ubuntu
22.04+, Debian 12+ or RHEL 9+; building a Flutter Linux app at all also wants
`clang cmake ninja-build libgtk-3-dev lld`, and `flutter doctor` names whichever
of those you are missing.

**Web** — three script tags, plus one line in `initialize()`. The on-device
arm loads the runtime from a CDN, and that ES module assigns no window
globals — module scripts are deferred, so Dart would reach the engine before
the constructor exists. `web/index.html` publishes a promise instead, and
Dart awaits it. Every step app from this one on carries it in `<head>`:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
  return m.Engine;
})();
</script>

  <!-- Cache API for persistent storage -->
  <script src="cache_api.js"></script>

  <!-- OPFS Helper for large model streaming (>2GB) -->
  <script src="opfs_helper.js"></script>
```

`cache_api.js` and `opfs_helper.js` are copied byte-for-byte from the
`flutter_edge_ai` package's own `web/` directory — `installModel()` (and, in
general, `installEmbedder()`) call into them (via `window.cachePut` and
friends) to put model bytes into browser storage. Without them a web model
install fails. Copy both files into your app's `web/` directory alongside
`index.html`. Browser storage is not a permanent install, though: the bytes
survive a reload, the app's in-memory handle on them does not, so a reloaded
tab still reports the model installed and fetches it again. This app never
calls `installEmbedder()` on web, though — Step 5 explains why.

The matching Dart-side change is `webStorageMode: WebStorageMode.streaming`
on `FlutterEdgeAi.initialize()`, and size is the reason for it: streaming
hands `@litert-lm/core` a ReadableStream out of OPFS instead of buffering the
download into one blob, which browsers cap at roughly 2 GB — Chrome refuses
past it with `ERR_BLOB_OUT_OF_MEMORY`. Native platforms ignore the option.

The model itself changes on the web, and for a different reason than that
size limit. `@litert-lm/core` only runs dedicated web builds, and Gemma 3
1B — the model every native platform uses — has none: installing the native
file and creating an engine from it fails with
`Error: Streaming kTfLitePrefillDecode models is not supported yet.` So on
the web this app installs Gemma 4 E2B's web build instead
(`gemma-4-E2B-it-web.litertlm`, 2.0 GB — right on the ~2 GB blob limit that
streaming mode exists to sidestep, which is why streaming earns its keep here
and never had to on the ~0.6 GB native file), from the same ungated
`litert-community/gemma-4-E2B-it-litert-lm` repository the
[Multimodal](/codelabs/multimodal-flutter-gemma) codelab uses — no token
required for it. `LocalAIService` and `AiEngine` below both switch `_hfRepo`,
`_hfModelFile`, and the `ModelType` passed to `installModel` and
`FlutterEdgeAiModelConfig` on `kIsWeb`; native keeps Gemma 3 1B unchanged.

The web arm is an early preview: WebGPU, and text only. That matters for one
policy in particular — an image on **Smart** still routes to the cloud, which
is the only branch that declares vision anywhere.

### Update dependencies

Add `genkit_flutter_edge_ai` and `flutter_edge_ai`:

```yaml
  # Step 3: On-device AI (LiteRT-LM engine)
  genkit_flutter_edge_ai: ^0.6.2
  flutter_edge_ai: ^1.11.4
  # flutter_edge_ai 1.x registers no engine by default — opt into LiteRT-LM
  # (.litertlm inference) here.
  flutter_edge_ai_litertlm: ^1.8.6
  # Step 5 embeds your documents. The engine above runs the forward pass;
  # this package supplies the tokenizers it needs.
  flutter_edge_ai_embeddings: ^2.2.1
```

Run `flutter pub get`.

### Get a HuggingFace token

Go to [huggingface.co](https://huggingface.co), sign in, and create a
read-access token at **Settings → Access Tokens**. Native platforms need it
because `litert-community/Gemma3-1B-IT` is gated; on the web, the app
installs Gemma 4 E2B's web build from an ungated repository instead (see the
Web setup above), so the token is optional there.

### Create LocalAIService

Create `lib/services/local_ai_service.dart`:

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

import 'ai_service.dart';

// The on-device LLM installs straight from Hugging Face by repo + file. The
// browser engine only runs dedicated web builds — Gemma 3 1B has none — so on
// web this installs Gemma 4 E2B's public web build instead (~2.0 GB, vs
// ~0.6 GB for the gated native file).
const String _hfRepo = kIsWeb
    ? 'litert-community/gemma-4-E2B-it-litert-lm'
    : 'litert-community/Gemma3-1B-IT';
const String _hfModelFile = kIsWeb
    ? 'gemma-4-E2B-it-web.litertlm'
    : 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const ModelType _modelType = kIsWeb ? ModelType.gemma4 : ModelType.gemmaIt;

// Pass at build time: flutter run --dart-define=HF_TOKEN=hf_xxx
const String _hfToken = String.fromEnvironment('HF_TOKEN');

const String _modelName = 'gemma-3-1b-it';
const String _embedderName = 'embedding-gemma-300m';

class LocalAIService implements AIService {
  Genkit? _ai;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  // Shared Genkit instance exposed for RagService to use for embeddings.
  Genkit get ai {
    final ai = _ai;
    if (ai == null) throw StateError('LocalAIService not initialized');
    return ai;
  }

  String get embedderName => _embedderName;

  @override
  Future<void> initialize({void Function(int)? onProgress}) async {
    if (_isInitialized) return;

    // flutter_edge_ai 1.x registers no engine by default — opt into LiteRT-LM.
    // `webStorageMode: streaming` (OPFS-backed) is what the size demands: the
    // 2.0 GB web build sits right on the ~2 GB blob ceiling the default
    // cacheApi mode would have to buffer it into, so the @litert-lm/core
    // engine reads it from OPFS as a ReadableStream. Ignored on non-web.
    await FlutterEdgeAi.initialize(
      webStorageMode: WebStorageMode.streaming,
      inferenceEngines: [LiteRtLmEngine()],
    );

    // Download the .litertlm model (skipped if already installed).
    await FlutterEdgeAi.installModel(
          modelType: _modelType,
          fileType: ModelFileType.litertlm,
        )
        .fromHuggingFace(
          _hfRepo,
          file: _hfModelFile,
          token: _hfToken.isEmpty ? null : _hfToken,
        )
        .withProgress((p) => onProgress?.call(p)) // p is int 0..100
        .install();

    // No installEmbedder() call here: this app never computes an embedding
    // (RagService doesn't exist until Step 6, by which point this whole
    // file is retired — see Step 4) and initialize() registers no embedding
    // backend either, so downloading the ~300 MB model here would just be
    // wasted bandwidth. embedderName/embedders below stay purely
    // declarative, ready for Step 4's AiEngine to actually install it.

    // One Genkit instance for both inference and embeddings.
    _ai = Genkit(
      plugins: [
        GenkitFlutterEdgeAiPlugin(
          models: [
            FlutterEdgeAiModelConfig(
              name: _modelName,
              modelType: _modelType,
              fileType: ModelFileType.litertlm,
            ),
          ],
          embedders: [FlutterEdgeAiEmbedderConfig(name: _embedderName)],
        ),
      ],
    );

    _isInitialized = true;
  }

  @override
  Stream<String> generateResponseStream(String prompt) async* {
    final stream = ai.generateStream(
      model: flutterEdgeAi.model(_modelName),
      prompt: prompt,
    );

    await for (final chunk in stream) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  @override
  Future<void> dispose() async {
    _ai = null;
    _isInitialized = false;
  }
}
```

Three things in that file run ahead of this step — the `ai` getter,
`embedderName`, and the `embedders:` entry in `GenkitFlutterEdgeAiPlugin`.
They ship here so that the RAG step is a new file and not a second edit of
this one; ignore them until then. There's no `installEmbedder()` call to run
ahead of, though: nothing in this app, now or later in its short life,
computes an embedding, so there's nothing to gain from downloading one.
Step 4's `AiEngine` installs it for real, once RAG is actually on the way.

### Run with HuggingFace token

```bash
flutter run --dart-define=GEMINI_API_KEY=your_key --dart-define=HF_TOKEN=hf_xxx
```

The first run downloads ~550 MB (~2.0 GB on the web, for Gemma 4 E2B instead
of Gemma 3 1B). Subsequent runs use the cached model.

> **Key insight**: Notice that `generateResponseStream` looks identical to
> `CloudAIService` — only the `model:` parameter changes. Genkit decouples
> _what model to use_ from _how to call it_.

```dart
// Cloud:
ai.generateStream(model: googleAI.gemini('gemini-3.7-flash'), prompt: prompt)

// Local:
ai.generateStream(model: flutterEdgeAi.model('gemma-3-1b-it'), prompt: prompt)
```

Same API. Different backends.

> **Coming up**: In Step 4 we retire `CloudAIService` and `LocalAIService` as
> separate classes. A single `AiEngine` builds one `Genkit` with both plugins
> registered, and `genkit_hybrid` composes the two resolved models into one
> routable `Model` — the app still calls `ai.generateStream(model: ..., ...)`,
> it just gets that one `Model` from `AiEngine` instead of picking a service.

## Step 4: Hybrid Strategy
Duration: 15

### Update dependencies

Add `genkit_hybrid` — the routing layer. Everything else (the cloud + on-device
plugins and `flutter_edge_ai_litertlm`) is already in place from Steps 2–3:

```yaml
  # Hybrid on-device ↔ cloud routing
  genkit_hybrid: ^0.2.1
```

Run `flutter pub get`.

### Retire CloudAIService, LocalAIService

```bash
rm lib/services/ai_service.dart lib/services/cloud_ai_service.dart \
   lib/services/local_ai_service.dart
```

They're replaced by one `AiEngine` that owns a single `Genkit` instance for
both plugins.

### Create AiEngine

Create `lib/services/ai_engine.dart`:

```dart
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart' show GenkitPlugin;
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

// Prod installs the on-device LLM straight from Hugging Face by repo + file
// (the plugin applies the configured token to gated huggingface.co URLs). The
// browser engine only runs dedicated web builds — Gemma 3 1B has none — so on
// web this installs Gemma 4 E2B's public web build instead (~2.0 GB, vs
// ~0.6 GB for the gated native file).
const _hfRepo = kIsWeb
    ? 'litert-community/gemma-4-E2B-it-litert-lm'
    : 'litert-community/Gemma3-1B-IT';
const _hfModelFile = kIsWeb
    ? 'gemma-4-E2B-it-web.litertlm'
    : 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const _modelType = kIsWeb ? ModelType.gemma4 : ModelType.gemmaIt;
const _embeddingModelUrl =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerUrl =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model';

// Pass at build time: --dart-define=HF_TOKEN=hf_xxx --dart-define=GEMINI_API_KEY=AIza...
const _hfToken = String.fromEnvironment('HF_TOKEN');
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

const kLocalModel = 'gemma-3-1b-it';
const kCloudModel = 'gemini-3.7-flash';
const kEmbedder = 'embedding-gemma-300m';

/// Context window for the on-device branch, in tokens. `maxTokens` is the
/// WHOLE window (input + output) and genkit_flutter_edge_ai defaults it to 1024.
/// RagService's take(3) of ~600-token city guides alone is ~1.7k tokens —
/// measured on device: "Input token ids are too long … 1713 >= 1024". The
/// bundled Gemma-3-1B `.litertlm` is built for 4096 (`ekv4096`), so use it.
const kOnDeviceContextTokens = 4096;

/// The five routing policies the chat exposes. Each maps to one genkit_hybrid
/// construct (see [modelFor] / [strategyFor]), and carries the UI facts about
/// itself — its label, which branches it needs, whether it is text-only — so
/// the screen renders the dropdown from `PolicyMode.values` instead of
/// restating all five modes by hand.
enum PolicyMode {
  cloud('Cloud', needsLocal: false),
  local('Local', needsCloud: false, textOnly: true),
  smart('Smart (image-aware)'),
  cascade('Cascade (escalate on quality)', textOnly: true),
  budget('Budget (cost-gated)');

  const PolicyMode(
    this.label, {
    this.needsCloud = true,
    this.needsLocal = true,
    this.textOnly = false,
  });

  /// Dropdown text.
  final String label;

  /// Which branches the composite for this mode requires.
  final bool needsCloud;
  final bool needsLocal;

  /// True when the primary route starts on the text-only on-device model, so
  /// an attached image cannot be handled (the UI blocks send with a hint).
  final bool textOnly;

  bool availableWith({required bool cloud, required bool local}) =>
      (!needsCloud || cloud) && (!needsLocal || local);
}

/// Owns a single Genkit instance with both plugins (cloud + on-device),
/// resolves the two base models, and composes them via genkit_hybrid per the
/// selected [PolicyMode]. Replaces the old Cloud/Local/HybridAIService trio.
class AiEngine {
  Genkit? _ai;
  Model? _local;
  Model? _cloud;

  /// One composite [Model] per policy, built AND registered once by
  /// [_registerPolicyModels] — genkit reduces `generate(model: ...)` to the
  /// model's name and looks it up in the registry, so a freshly built,
  /// never-registered composite would fail every call with NOT_FOUND.
  final Map<PolicyMode, Model> _models = {};

  bool cloudReady = false;
  bool localReady = false;

  // CostStrategy demo signal: the app counts cloud calls against a small cap.
  int cloudCallsSpent = 0;
  int budgetCap = 3;
  bool get budgetAvailable => cloudCallsSpent < budgetCap;

  AiEngine();

  /// Test seam: skips [FlutterEdgeAi.initialize]/`installModel` (real I/O that
  /// can't run in a unit test) and takes already-resolved branch models
  /// directly, then runs the same build+register path [initialize] uses — so
  /// a test driving [modelFor] through `ai.generate` here exercises the real
  /// registration wiring, not just [strategyFor]. [local] is nullable —
  /// mirrors [cloud] — so a cloud-only engine (the symmetric mirror of the
  /// cloud-absent case) is constructible too.
  @visibleForTesting
  AiEngine.forTest({required Genkit ai, Model? local, Model? cloud}) {
    _ai = ai;
    _local = local == null ? null : _withContextBudget(local);
    _cloud = cloud;
    localReady = local != null;
    cloudReady = cloud != null;
    _registerPolicyModels();
  }

  Genkit get ai {
    final ai = _ai;
    if (ai == null) throw StateError('AiEngine not initialized');
    return ai;
  }

  String get embedderName => kEmbedder;

  Future<void> initialize({
    void Function(int progress)? onProgress,
    // Test seam: install the LLM from a pre-staged local file instead of
    // downloading it — avoids a flaky ~500MB on-device download on CI / FTL.
    String? localModelPath,
    // Test seam: skip the embedder download when RAG isn't exercised.
    bool downloadEmbedder = true,
  }) async {
    // RAG runs on every platform, web included. The four LiteRT.js files in
    // web/ come from flutter_edge_ai_litertlm, which owns that bundle; the
    // WASM runtime behind them is fetched from a CDN, so there is
    // nothing else to host. The only thing left that can turn embeddings off
    // here is the test seam.
    final embeddingsSupported = downloadEmbedder;

    // Declarative plugin config — always includes the on-device plugin (its
    // models/embedders are looked up by name later, independent of whether
    // the install below actually succeeds).
    final plugins = <GenkitPlugin>[
      if (_geminiApiKey.isNotEmpty) googleAI(apiKey: _geminiApiKey),
      GenkitFlutterEdgeAiPlugin(
        models: [
          FlutterEdgeAiModelConfig(
            name: kLocalModel,
            modelType: _modelType,
            fileType: ModelFileType.litertlm,
          ),
        ],
        embedders: embeddingsSupported
            ? [FlutterEdgeAiEmbedderConfig(name: kEmbedder)]
            : const [],
      ),
    ];

    // Build Genkit BEFORE any on-device engine registration/install so `_ai`
    // (and `_resolve`, and the `ai` getter) are always available afterward —
    // the plugin list above is purely declarative (no I/O, no dependency on
    // FlutterEdgeAi.initialize() having run), so cloud resolution below needs
    // no on-device engine and must not be taken down by a failure
    // registering/installing it.
    _ai = Genkit(plugins: plugins);

    // CLOUD: needs no install, so its readiness never depends on the local
    // LLM or the (optional) embedder below.
    if (_geminiApiKey.isNotEmpty) {
      try {
        _cloud = await _resolve(googleAI.gemini(kCloudModel));
        cloudReady = true;
      } catch (e) {
        debugPrint('⚠️ AiEngine: CLOUD backend unavailable — $e');
        cloudReady = false;
      }
    }

    // LOCAL: register the on-device engine, then install + resolve the LLM.
    // flutter_edge_ai 1.x registers no engines by default; that registration
    // now lives inside this try/catch (not before Genkit is built) so an
    // engine-init failure only suppresses localReady, never cloud.
    try {
      // Opt into LiteRT-LM (.litertlm inference) +, off web, its LiteRT
      // embedding backend (see embeddingsSupported above). `webStorageMode:
      // streaming` (OPFS-backed) is what the size demands: the 2.0 GB web
      // build sits right on the ~2 GB blob ceiling the default cacheApi
      // mode would have to buffer it into, so the @litert-lm/core engine
      // reads it from OPFS as a ReadableStream. Ignored on non-web.
      await FlutterEdgeAi.initialize(
        webStorageMode: WebStorageMode.streaming,
        inferenceEngines: [LiteRtLmEngine()],
        embeddingBackends: embeddingsSupported
            ? [LiteRtEmbeddingBackend()]
            : const [],
        // A backend no longer carries a tokenizer: which one a model needs is
        // a property of the model, so the app
        // registers it. Without this the first embedding throws a StateError.
        embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
      );

      // fileType MUST be litertlm to match the LiteRT-LM engine registered
      // above.
      final llm = FlutterEdgeAi.installModel(
        modelType: _modelType,
        fileType: ModelFileType.litertlm,
      );
      if (localModelPath != null) {
        await llm.fromFile(localModelPath).install();
      } else {
        await llm
            .fromHuggingFace(
              _hfRepo,
              file: _hfModelFile,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .withProgress((p) => onProgress?.call(p)) // p is int 0..100
            .install();
      }
      _local = _withContextBudget(
        await _resolve(flutterEdgeAi.model(kLocalModel)),
      );
      localReady = true;
    } catch (e) {
      debugPrint('⚠️ AiEngine: on-device backend unavailable — $e');
      localReady = false;
    }

    // EMBEDDER (OPTIONAL): RAG-only, never blocks chat — a
    // failure here must not flip localReady or rethrow.
    if (embeddingsSupported && localReady) {
      try {
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(
              _embeddingModelUrl,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .tokenizerFromNetwork(
              _tokenizerUrl,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .install();
      } catch (e) {
        debugPrint('⚠️ AiEngine: embedder install failed, RAG disabled — $e');
      }
    }

    _registerPolicyModels();
  }

  // A plugin model is registered by name; genkit's `Model` is an `Action`, so
  // look the concrete model up from the registry and cast.
  Future<Model> _resolve(ModelRef ref) async {
    final action = await ai.registry.lookupAction(ActionType.model, ref.name);
    if (action == null) {
      throw StateError('model "${ref.name}" is not registered');
    }
    return action as Model;
  }

  /// Wraps the on-device branch so every request carries the context budget
  /// unless the caller set one. Copies the request rather than mutating it:
  /// genkit_hybrid hands the SAME ModelRequest to the next branch when
  /// cascade escalates, so an in-place write would leak a Gemma-only
  /// maxTokens into the Gemini call. The metadata copy is required too —
  /// genkit's Model constructor writes into the map it is handed.
  Model _withContextBudget(Model inner) => Model(
    name: '${inner.name}/ctx',
    metadata: {...inner.metadata},
    fn: (request, context) {
      if (request == null || request.config?['maxTokens'] != null) {
        return inner.fn(request, context);
      }
      final budgeted = ModelRequest.fromJson({
        ...request.toJson(),
        'config': {...?request.config, 'maxTokens': kOnDeviceContextTokens},
      });
      return inner.fn(budgeted, context);
    },
  );

  Map<String, Model> get _branches => {kOnDevice: ?_local, kCloud: ?_cloud};

  /// Builds AND registers one composite [Model] per [PolicyMode] whose
  /// required branches are available, populating [_models]. A mode that needs
  /// `kCloud` (every mode but `local`) is skipped when there's no API key, so
  /// a missing cloud branch degrades to a clear [modelFor] error instead of
  /// crashing here on a half-built `cascadeModel` (its `order` validates
  /// eagerly against `branches`, unlike `hybridModel`).
  void _registerPolicyModels() {
    for (final mode in PolicyMode.values) {
      if (!mode.availableWith(cloud: _cloud != null, local: _local != null)) {
        continue;
      }
      final model = _buildModel(mode);
      ai.registry.register(model);
      _models[mode] = model;
    }
  }

  /// The composable Genkit `Model` for [mode]. Cascade is a `cascadeModel`;
  /// every other mode is `hybridModel(strategy: strategyFor(mode))`. Called
  /// once per mode by [_registerPolicyModels] — not a per-request factory.
  Model _buildModel(PolicyMode mode) {
    if (mode == PolicyMode.cascade) {
      return cascadeModel(
        branches: _branches,
        order: const [kOnDevice, kCloud],
        // DEMO PROXY — not a real quality signal. A production cascade
        // escalates on model *confidence*; the best training-free signal is
        // the reply's average token log-probability. We can't use it here:
        // LiteRT-LM gives `accept` only decoded text (no per-token
        // probabilities), and asking a ~1B model to self-rate confidence is
        // unreliable — small models are confidently wrong. So we escalate on a
        // crude "too short to be a real answer" check. See the codelab's
        // "A real cascade signal" note.
        accept: (r) => r.text.trim().length > 20,
        name: 'cascade',
      );
    }
    return hybridModel(
      branches: _branches,
      strategy: strategyFor(mode),
      name: mode.name,
    );
  }

  /// The registered, resolvable `Model` for [mode] — built once by
  /// [_registerPolicyModels] during [initialize] (or [AiEngine.forTest]).
  Model modelFor(PolicyMode mode) {
    final model = _models[mode];
    if (model == null) {
      throw StateError(
        'No model registered for $mode — call initialize() first (or, if '
        'this mode needs the cloud branch, make sure a cloud API key is set).',
      );
    }
    return model;
  }

  /// Pure policy → RoutingStrategy mapping (no models needed), so the routing
  /// decisions are unit-testable. [PolicyMode.cascade] has no strategy — it is
  /// a Model, built in [_buildModel].
  RoutingStrategy strategyFor(PolicyMode mode) {
    switch (mode) {
      case PolicyMode.cloud:
        return PreRoutingStrategy((_) => kCloud);
      case PolicyMode.local:
        return PreRoutingStrategy((_) => kOnDevice);
      case PolicyMode.smart:
        // Image → cloud only (only it declares vision). Text → both qualify,
        // cloud-first in `supports` insertion order, on-device as the tail.
        // No WithFallback: CapabilityStrategy already yields the on-device
        // tail for text, and for an image a forced on-device tail would hand
        // the picture to a model that cannot see it. Offline + image should
        // fail loudly, not silently degrade to text-only.
        return CapabilityStrategy(
          supports: {
            kCloud: {ModelCapability.vision},
            kOnDevice: <ModelCapability>{},
          },
        );
      case PolicyMode.budget:
        return CostStrategy(
          budgetAvailable: () => budgetAvailable,
          premium: kCloud,
          cheap: kOnDevice,
        );
      case PolicyMode.cascade:
        throw ArgumentError('cascade has no RoutingStrategy; use modelFor');
    }
  }

  void dispose() {
    _ai = null;
    _local = null;
    _cloud = null;
    _models.clear();
  }
}
```

`kOnDevice` and `kCloud` are branch-key constants exported by `genkit_hybrid`
itself — reuse them instead of inventing your own strings so every strategy
agrees on the same keys.

For **Step 4** we only need `PolicyMode.cloud` and `PolicyMode.local`:
`strategyFor` maps each straight to a `PreRoutingStrategy` that always
returns one key. `smart`, `cascade`, and `budget` are covered in Step 4.5 —
`strategyFor(PolicyMode.cascade)` deliberately throws, because cascade isn't
a `RoutingStrategy` at all; `_buildModel` builds it as a `cascadeModel`
directly.

Three things in that file run ahead of this step, and are there so you never
have to go back and edit it. `AiEngine.forTest` and `initialize`'s
`localModelPath` are test seams — they let `test/ai_engine_policy_test.dart`
drive the real registration path without a 550 MB download.
`_withContextBudget` is Step 6's, and Step 6 explains it; until RAG inflates
the prompt it changes nothing you can observe.

### The hybrid is itself a Model

> **The punchline**: `hybridModel()` (and `cascadeModel()`) return an
> ordinary Genkit `Model`. Nothing downstream needs to know routing
> happened — the result composes with everything a normal model composes
> with: streaming, a RAG-augmented prompt, images. `AiEngine.modelFor(mode)`
> is a drop-in replacement for `googleAI.gemini(...)` or
> `flutterEdgeAi.model(...)`.
>
> **But an ordinary `Model` still has to be registered.** genkit resolves
> `generate(model: ...)` (and `generateStream`) by reducing it to its `.name`
> and looking that name up in `ai.registry` — a `Model` you built but never
> registered fails every call with `NOT_FOUND`. That's why `initialize()`
> calls `_registerPolicyModels()` right after resolving `_local`/`_cloud`:
> it builds and registers all five policy composites *once*, up front, and
> `modelFor` just returns the already-registered instance from `_models`.
> Building a fresh `hybridModel`/`cascadeModel` inside `modelFor` itself —
> without registering it — is the one thing to avoid here.

### Add the policy picker

In `chat_screen.dart`, replace the strategy toggle with a `DropdownButton`
over all five `PolicyMode` values. There's nothing to hand-write per mode:
the enum already knows its own label and its own prerequisites, so the item
list is a loop and a new policy shows up in the picker the moment you add it
to the enum.

```dart
Padding(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  child: DropdownButton<PolicyMode>(
    value: _policy,
    isExpanded: true,
    items: [
      for (final mode in PolicyMode.values)
        DropdownMenuItem(
          value: mode,
          enabled: mode.availableWith(
            cloud: _engine.cloudReady,
            local: _engine.localReady,
          ),
          child: Text(mode.label),
        ),
    ],
    onChanged: (m) {
      if (m != null) setState(() => _policy = m);
    },
  ),
),
```

`availableWith` is what keeps a half-ready app honest: with no API key only
**Local** is selectable, and until the on-device model finishes downloading
only **Cloud** is.

### Drive generateStream from modelFor

`_sendMessage()` no longer picks between two services — it always calls the
same `Genkit`, and lets `AiEngine.modelFor(_policy)` decide who answers:

```dart
final userMessage = Message(
  role: Role.user,
  content: [TextPart(text: text)],
);
// ...
// Captured before the call: genkit_hybrid doesn't report which branch
// actually ran, so this is a best-effort demo counter, not an exact
// count of cloud calls — see the accounting comment below.
final wasBudgetAvailable = _engine.budgetAvailable;

final stream = _engine.ai.generateStream(
  model: _engine.modelFor(_policy),
  messages: [userMessage],
);
await for (final chunk in stream) {
  buffer.write(chunk.text);
  // ... the throttled setState loop, unchanged from Step 2/3
}
// ...
// Best-effort demo counter for CostStrategy: genkit_hybrid exposes no
// "which branch ran" signal, so a Budget call that transiently fell
// back to on-device still counts here as spent; Budget stops climbing
// once the cap is hit either way.
if (_policy == PolicyMode.cloud) {
  _engine.cloudCallsSpent++;
} else if (_policy == PolicyMode.budget && wasBudgetAvailable) {
  _engine.cloudCallsSpent++;
}
```

`text` goes straight to the model here. In Step 6 RAG rewrites it first,
and the local is renamed `prompt` to say so — the call itself does not
change.

### Test it

1. Switch to **Cloud** and send a message — Gemini answers.
2. Switch to **Local** and send a message — Gemma 3 1B answers.
3. Leave **Smart**, **Cascade**, and **Budget** for Step 4.5 — right now
   `strategyFor` treats them correctly, but nothing exercises their
   interesting behavior (an image, a bad on-device answer, a spent budget)
   until then.

## Step 4.5: Smart routing & images
Duration: 20

Three of the five `PolicyMode` values only get interesting once the app can
send more than plain text, and once there's a signal to route on besides "the
user picked cloud or local." This step adds image input, wires it through
`CapabilityStrategy`, and walks through what `smart`, `cascade`, and `budget`
actually decide.

### Update dependencies

```yaml
  # Image input (multimodal)
  image_picker: ^1.2.3
```

Run `flutter pub get`.

### Attach an image

In `chat_screen.dart`, add the picker and its state:

```dart
import 'dart:convert';
import 'dart:typed_data';
// ...
import 'package:image_picker/image_picker.dart';

// in _ChatScreenState:
final _picker = ImagePicker();
Uint8List? _attachedImage;
String? _attachedMime;

// ...
Future<void> _attachImage() async {
  final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);
  if (picked == null) return;
  final bytes = await picked.readAsBytes();
  if (!mounted) return;
  setState(() {
    _attachedImage = bytes;
    _attachedMime = picked.mimeType ?? 'image/jpeg';
  });
}
```

Add an `IconButton(icon: const Icon(Icons.image_outlined))` next to the send
button that calls `_attachImage`, and a small thumbnail preview (`Image.memory`
+ a close button) shown above the input row while `_attachedImage != null`.

### Build a multimodal message

`_sendMessage()` now builds a `content` list instead of a single `TextPart`:

```dart
final content = <Part>[TextPart(text: text)];
if (_attachedImage != null) {
  final mime = _attachedMime ?? 'image/jpeg';
  final dataUri = 'data:$mime;base64,${base64Encode(_attachedImage!)}';
  // contentType MUST be set: the on-device plugin drops media without an
  // image/* contentType, and CapabilityStrategy reads it to detect vision.
  content.add(
    MediaPart(
      media: Media(contentType: mime, url: dataUri),
    ),
  );
}
final userMessage = Message(role: Role.user, content: content);
```

`contentType` is the load-bearing detail for the on-device converter:
`genkit_flutter_edge_ai` drops any `MediaPart` whose `Media.contentType` isn't
set, so an `image_picker` file with no MIME type falls back to
`'image/jpeg'` rather than being silently dropped. `CapabilityStrategy`
(below) is more forgiving — it also recognizes vision from a `data:image/…`
URL or a recognized image file extension — but setting `contentType`
explicitly is what the on-device plugin requires, so do it regardless of
which strategy is routing.

### Smart, Cascade, and Budget

Back in `AiEngine.strategyFor`, the three remaining cases:

```dart
case PolicyMode.smart:
  // Image → cloud only (only it declares vision). Text → both qualify,
  // cloud-first in `supports` insertion order, on-device as the tail.
  // No WithFallback: CapabilityStrategy already yields the on-device
  // tail for text, and for an image a forced on-device tail would hand
  // the picture to a model that cannot see it. Offline + image should
  // fail loudly, not silently degrade to text-only.
  return CapabilityStrategy(
    supports: {
      kCloud: {ModelCapability.vision},
      kOnDevice: <ModelCapability>{},
    },
  );
case PolicyMode.budget:
  return CostStrategy(
    budgetAvailable: () => budgetAvailable,
    premium: kCloud,
    cheap: kOnDevice,
  );
```

- **Smart** — `CapabilityStrategy` inspects the outgoing `ModelRequest` for
  media parts and keeps the branches that declare what the request needs. A
  text-only request needs nothing, so both branches qualify and it returns
  `[kCloud, kOnDevice]` (cloud-first, in `supports`' insertion order) — the
  on-device tail is already there, for free, and `hybridModel` uses it when
  the cloud call throws. An image request requires `vision`, which only
  `kCloud` declares, so it returns `[kCloud]` and nothing else: there is no
  second branch to fall to, by design.
- **Cascade** — built in `_buildModel`, not `strategyFor`:
  `cascadeModel(branches: _branches, order: [kOnDevice, kCloud], accept: (r) => r.text.trim().length > 20)`.
  It tries the on-device model first; if the response passes `accept` (here,
  "longer than 20 characters") it's returned as-is, otherwise it escalates to
  cloud. `cascadeModel` is **non-streaming internally** — even through
  `ai.generateStream`, a cascade-routed request buffers the whole winning
  response and emits it as a single chunk.
- **Budget** — `CostStrategy` returns `[premium, cheap]` while
  `budgetAvailable()` is true, `[cheap]` once it isn't. `AiEngine` owns the
  budget itself: `cloudCallsSpent` is a plain int the app increments after
  every `cloud`/`budget` call (see the `_sendMessage` snippet above) and
  compares against `budgetCap` (3 by default). `genkit_hybrid` has no billing
  SDK — it only ever sees the resulting `bool`.

> **A real cascade signal.** That `accept` predicate is a *deliberately crude*
> demo proxy — "long enough" is a poor stand-in for "good enough" (a correct
> `"Paris."` escalates needlessly; 25 characters of nonsense passes). A
> production cascade escalates on model **confidence**, and the strongest
> training-free signal is the reply's **average token log-probability** — how
> surprised the model was by its own tokens; it decisively beats other
> zero-shot signals and holds up out-of-distribution. We fall back to a length
> check for one honest reason: the on-device runtime (LiteRT-LM) returns only
> decoded text, so `accept` never sees per-token probabilities. And resist the
> obvious shortcut of asking the model to score its own confidence — a ~1B
> model is badly calibrated and *confidently wrong*, which makes verbalized
> self-confidence a worse signal than the crude length check. (See
> [Zero-Shot Confidence for Small LLMs](https://arxiv.org/abs/2605.02241) and
> [Do Small LMs Know When They're Wrong?](https://arxiv.org/abs/2604.19781).)

> **Smart + image on a cloud outage fails, and that's the point**: with an
> attached image, `CapabilityStrategy` returns `[kCloud]` — the only branch
> that declares vision — and nothing behind it. Offline, that call throws and
> the error reaches the chat as `Error: ...`. An earlier version of this app
> wrapped Smart in `WithFallback(..., fallbackOrder: [kOnDevice])`, which
> appended the on-device model as a tail for *both* shapes of request; the
> picture then went to a model that can't see it and got answered from the
> question's text alone — a confident, plausible reply about a photo nobody
> read. A wrong answer nobody flags is worse than a visible failure, so the
> wrapper is gone. Text is unaffected: `CapabilityStrategy` puts `kOnDevice`
> behind `kCloud` on its own, so an offline text question still lands on the
> phone.
>
> **Budget shares its counter with Cloud**: `cloudCallsSpent` is one counter,
> not one per policy — a Cloud-mode send also spends the Budget allowance.
> Demo Cloud before Budget and the allowance may already be partly (or
> fully) spent by the time you switch.

### The capability block

An image can't reach a policy whose primary route is the text-only on-device
model — which is exactly the `textOnly` flag each `PolicyMode` already
carries, so there's no helper to write and no second list of modes to keep in
sync. `_sendMessage()` checks it before doing anything else:

```dart
if (_attachedImage != null && _policy.textOnly) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        "The on-device model can't see images — switch to Smart or Cloud.",
      ),
    ),
  );
  return;
}
```

`local` always starts on-device; `cascade`'s first hop is always on-device
too — both are declared `textOnly: true` and blocked. `smart` and `cloud`
send an image to `kCloud` and nowhere else, so they're let through.
`budget` is let through as well, but that's the one optimistic case: once
`cloudCallsSpent` hits `budgetCap`, `CostStrategy` routes to `[kOnDevice]`
only — `textOnly` is a fact about the policy, not about its current spend, so
an image sent on a spent budget still isn't guaranteed a vision-capable
branch.

### Manual runbook

1. Send a text message in each of the five modes — Cloud, Local, Smart,
   Cascade, Budget — and confirm each one answers.
2. Attach an image, switch to **Smart**, and send — the response comes from
   Gemini (`CapabilityStrategy` routes the vision request straight to
   `kCloud`).
3. Turn off WiFi, stay on **Smart**, and send a text message — the cloud
   attempt fails and `hybridModel` moves on to `kOnDevice`, the tail
   `CapabilityStrategy` returned for a text request (slower, but it answers).
   Now attach an image and send that instead: this one fails with
   `Error: ...`, because a vision request has no on-device tail to move on
   to.
4. Turn WiFi back on, switch to **Budget**, and keep sending text messages.
   `cloudCallsSpent` counts every completed Cloud- or Budget-mode call
   cumulatively for the whole session — including the Cloud-mode message
   from step 1 — so it may already be close to `budgetCap` (3) by the time
   you get here. Once it reaches the cap, routing flips to on-device only
   (`CostStrategy` sees `budgetAvailable == false`); a hot restart resets
   the counter to 0 if you want to watch it flip from a clean count.
5. Switch to **Local** and attach an image — send is blocked before any
   request goes out, with the "can't see images" snackbar.

`flutter test test/ai_engine_policy_test.dart` exercises the same
`strategyFor` routes and `PolicyMode` facts as a fast, deviceless unit test —
useful to rerun after touching routing logic instead of redoing the whole
runbook by hand.

## Step 5: Embeddings with Genkit
Duration: 20

### How embeddings work

An embedding turns text into a vector of numbers that captures semantic meaning.
Similar texts have similar vectors. EmbeddingGemma 300M runs entirely on-device.

### Web setup for embeddings

Copy four files into `web/`, the same way you copied `cache_api.js` and
`opfs_helper.js` in Step 3:

```
litert.js   litert_embeddings.js   sentencepiece.js   tensorflow.js
```

They come from `flutter_edge_ai_litertlm/web/`. The bundle moved there in the
legacy `flutter_gemma_litertlm` 1.8.0 release and remains owned by the current
package. Then load the entry point in `web/index.html`:

```html
<script type="module" src="litert_embeddings.js"></script>
```

That is the whole web setup. The WASM runtime underneath is fetched from a
CDN, so there is nothing else to host.

> An earlier version of this codelab told you embeddings could not run in a
> browser at all. That was true then: the bundle was split across two packages
> and the WASM runtime it needs was not published anywhere, so the four files
> loaded without error and had nothing to call underneath them. Both are fixed
> in legacy `flutter_gemma_litertlm` 1.8.0 and remain fixed in the current
> `flutter_edge_ai_litertlm` package.

One thing the app must do on every platform, not just web: register a
tokenizer. That change shipped in legacy `flutter_gemma` 1.9.0 and is part of
the current `flutter_edge_ai`: an embedding backend no longer carries one —
which tokenizer a model needs is a property of the model, not of the engine
that runs it — so `AiEngine.initialize()` passes
`embeddingTokenizers: const [GemmaEmbeddingTokenizers()]` beside
`embeddingBackends:`. Leave it out and the first embedding throws a
`StateError` naming the package to add.

### Install the embedding model

This already runs inside `AiEngine.initialize()`, in the optional block after
the LLM install, on every platform. A failure disables RAG and never touches
the chat:

```dart
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      _embeddingModelUrl,
      token: _hfToken.isEmpty ? null : _hfToken,
    )
    .tokenizerFromNetwork(
      _tokenizerUrl,
      token: _hfToken.isEmpty ? null : _hfToken,
    )
    .install();
```

### Register the embedder with Genkit

There's no second `Genkit` to build — `AiEngine` already declared the embedder
back in Step 4, right next to the on-device model in the *same*
`GenkitFlutterEdgeAiPlugin`, gated by the same `embeddingsSupported`:

```dart
GenkitFlutterEdgeAiPlugin(
  models: [
    FlutterEdgeAiModelConfig(
      name: kLocalModel,
      modelType: _modelType,
      fileType: ModelFileType.litertlm,
    ),
  ],
  embedders: embeddingsSupported
      ? [FlutterEdgeAiEmbedderConfig(name: kEmbedder)]
      : const [],
),
```

So the one `AiEngine` Genkit already exposes the embedder — you just call
`ai.embed(...)` on it (next).

### Generate embeddings

```dart
final embeddings = await _ai.embed(
  embedder: flutterEdgeAi.embedder(_embedderName),
  document: DocumentData(content: [TextPart(text: content)]),
);
```

`embeddings.first.embedding` is the `List<double>` — 768 numbers for
EmbeddingGemma 300M.

### Index the tourist data

Create `lib/services/rag_service.dart`. In `initialize()`, loop over 10 city
JSON files and embed each one. Store the `List<double>` vectors in memory.

```dart
for (final city in _cityFiles) {
  onStatus?.call('Embedding $city...');
  final jsonString = await rootBundle.loadString(
    'assets/tourist_data/$city.json',
  );
  final data = jsonDecode(jsonString) as Map<String, dynamic>;

  final name = data['name'] as String? ?? city;
  final content = _buildContent(data);

  final embeddings = await _ai.embed(
    embedder: flutterEdgeAi.embedder(_embedderName),
    document: DocumentData(content: [TextPart(text: content)]),
  );

  _store.add(
    _VectorDocument(
      id: city,
      content: content,
      city: name,
      embedding: embeddings.first.embedding,
    ),
  );
}
```

> **Key insight**: `ai.embed(embedder: ...)` is model-agnostic. Replace
> `flutterEdgeAi.embedder(...)` with any other registered embedder — the rest
> of the code stays the same.

## Step 6: RAG — Retrieval-Augmented Generation
Duration: 20

### Wire RagService to AiEngine

`RagService` doesn't manage its own `Genkit` instance or model installation —
it takes both from `AiEngine`, the same way `_sendMessage` does:

```dart
final rag = RagService(
  ai: _engine.ai,
  embedderName: _engine.embedderName,
);
await rag.initialize(
  onStatus: (s) {
    if (mounted) setState(() => _statusMessage = s);
  },
);
_ragService = rag;
_ragReady = true;
```

That block runs on every platform. If `RagService.initialize()` throws — a
missing JS file on web, a failed embedder install on native — the catch records
the reason instead of swallowing it:

```dart
} catch (e) {
  debugPrint('RAG init failed: $e');
  _ragUnavailableReason = '$e';
}
```

`build()` reads `_ragUnavailableReason` and shows a one-line banner under the
policy picker whenever it's set — RAG shows up as unavailable, with why,
instead of the toggle just staying disabled with no explanation.

### Semantic search

When the user sends a query, embed it and find the closest city documents
using cosine similarity. The two retrieval numbers get names — they're the
knobs you'll actually reach for, and one of them decides how much text the
on-device model has to swallow:

```dart
/// Minimum cosine similarity threshold for RAG retrieval results.
const double kMinSimilarity = 0.5;

/// Maximum number of documents to retrieve from the vector store.
const int kTopK = 3;

// ...

Future<RagResult> searchAndBuildContext(String query) async {
  if (!_isInitialized) throw StateError('RagService not initialized');

  final queryEmbeddings = await _ai.embed(
    embedder: flutterEdgeAi.embedder(_embedderName),
    document: DocumentData(content: [TextPart(text: query)]),
  );
  final queryVector = queryEmbeddings.first.embedding;

  final scored =
      _store
          .map(
            (doc) => (doc: doc, score: _cosine(queryVector, doc.embedding)),
          )
          .where((r) => r.score >= kMinSimilarity)
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

  final topK = scored.take(kTopK).toList();

  if (topK.isEmpty) {
    return RagResult(
      augmentedPrompt: query,
      retrievedContext: '',
      sources: [],
    );
  }

  final context = topK.map((r) => r.doc.content).join('\n\n');
  final sources = topK
      .map((r) => '${r.doc.city} (${(r.score * 100).toStringAsFixed(0)}%)')
      .toList();

  final augmentedPrompt =
      'Based on the following travel information:\n\n$context\n\n'
      'Answer the question: $query';

  return RagResult(
    augmentedPrompt: augmentedPrompt,
    retrievedContext: context,
    sources: sources,
  );
}
```

`_cosine` throws an `ArgumentError` when the two vectors' lengths disagree
rather than asserting it — an `assert` is compiled out of a release build,
which is precisely where a mismatched embedder would otherwise return
silent nonsense.

### Give the on-device branch room to read

`kTopK` is the first knob in this codelab that can break a working app.
Retrieval doesn't just improve the prompt, it *inflates* it — and the
on-device branch is answering inside a fixed window.

> **`maxTokens` is the whole context window, not the reply length.** It is the
> KV-cache budget: everything the model reads *plus* everything it writes.
> `genkit_flutter_edge_ai` defaults it to 1024, which is fine for the chat we've
> had so far and not fine the moment RAG lands. Three city guides at ~600
> tokens each is ~1.7k of prompt before the model has said a word, so the
> first RAG question on **Local** dies during prefill with
> `Input token ids are too long ... 1713 >= 1024` — a native error, not a bad
> answer. The fix isn't a smaller `kTopK`: the bundled Gemma 3 1B was built
> for a 4096-token window, which is what the `ekv4096` in its file name means.
> Give the on-device branch the window it already has.

Back in `AiEngine`, wrap the resolved on-device model so every request it
receives carries that budget:

```dart
/// Context window for the on-device branch, in tokens. `maxTokens` is the
/// WHOLE window (input + output) and genkit_flutter_edge_ai defaults it to 1024.
/// RagService's take(3) of ~600-token city guides alone is ~1.7k tokens —
/// measured on device: "Input token ids are too long … 1713 >= 1024". The
/// bundled Gemma-3-1B `.litertlm` is built for 4096 (`ekv4096`), so use it.
const kOnDeviceContextTokens = 4096;

// ... in initialize(), where the on-device model is resolved:
_local = _withContextBudget(
  await _resolve(flutterEdgeAi.model(kLocalModel)),
);

// ...

/// Wraps the on-device [inner] model so every request reaching it carries a
/// context window big enough for the RAG prompt. genkit_flutter_edge_ai reads
/// `maxTokens` ONLY from the per-request `request.config` (defaulting to
/// 1024) — registration-time [FlutterEdgeAiModelConfig] has no options field
/// — so the budget has to ride along with each request. genkit_hybrid calls
/// a branch as `branch.fn(request, context)`, so forwarding the same
/// `context` leaves streaming and fallback untouched. Only the on-device
/// branch is wrapped: Gemini's config has no `maxTokens` key. An explicit
/// request `maxTokens` wins. The request is COPIED, never mutated — cascade
/// hands the very same object to the cloud branch next. [inner]'s metadata
/// is forwarded as a COPY too: genkit's `Model` constructor writes into the
/// map it is handed, so passing `inner.metadata` itself would rewrite the
/// wrapped model's own metadata.
Model _withContextBudget(Model inner) => Model(
  name: '${inner.name}/ctx',
  metadata: {...inner.metadata},
  fn: (request, context) {
    if (request == null || request.config?['maxTokens'] != null) {
      return inner.fn(request, context);
    }
    final budgeted = ModelRequest.fromJson({
      ...request.toJson(),
      'config': {...?request.config, 'maxTokens': kOnDeviceContextTokens},
    });
    return inner.fn(budgeted, context);
  },
);
```

The cloud branch is untouched — Gemini's window is orders of magnitude
larger, and the wrapper only ever sees requests already routed on-device.

### Add RAG toggle to the UI

In `chat_screen.dart`:
1. Add a `Switch` in the `AppBar` to toggle RAG
2. In `_sendMessage()`, if RAG is enabled call `searchAndBuildContext(text)` before generating
3. Display `ragResult.sources` in a banner below the AppBar
4. Display `_ragUnavailableReason`, when set, in a banner of its own — the
   `Switch` alone (disabled, unlabeled) doesn't say *why* RAG is off

### Test it

Try these queries:
- "What should I eat in Tokyo?" → sources: Tokyo (92%)
- "Best European city for history?" → sources: Prague (78%), Istanbul (71%)
- "Tell me about the Eiffel Tower" → sources: Paris (95%)

If RAG fails to initialize on any platform, the `Switch` stays disabled and a
banner reports the reason rather than leaving the toggle silently off; the
rest of the app (all five policies, image input) keeps working.

## Step 7: Polish and Conclusion
Duration: 10

### Error handling and loading states

- Show download progress during model installation
- Disable a policy the app can't serve — that's `mode.availableWith(...)` in
  the picker
- Gate *every* send entry point, the button and `TextField.onSubmitted` alike,
  on the same condition — nothing in flight, and at least one branch ready
- Show "Generating..." indicator during streaming
- Graceful error messages in the chat

### What we built

| Capability | Technology |
|------------|-----------|
| Cloud inference | `genkit_google_genai` → Gemini 3.7 Flash |
| On-device inference | `genkit_flutter_edge_ai` → Gemma 3 1B |
| Hybrid routing | `genkit_hybrid` — `hybridModel`/`cascadeModel` (cloud, local, smart, cascade, budget) |
| Multimodal input | `image_picker` + `MediaPart`, routed by `CapabilityStrategy` |
| On-device embeddings | `genkit_flutter_edge_ai` → EmbeddingGemma 300M, including Web |
| RAG pipeline | Genkit `embed()` + in-memory cosine search, including Web |

### The Genkit advantage

The old approach needed two completely different APIs — Firebase AI Logic for
cloud and raw flutter_edge_ai calls for local. With Genkit:

```dart
// Both use the same API — only model: changes
ai.generateStream(model: googleAI.gemini('gemini-3.7-flash'), prompt: prompt)
ai.generateStream(model: flutterEdgeAi.model('gemma-3-1b-it'), prompt: prompt)
ai.embed(embedder: flutterEdgeAi.embedder('embedding-gemma-300m'), document: ...)

// genkit_hybrid composes both into one routable model — still the same call:
ai.generateStream(model: engine.modelFor(policy), messages: [userMessage])
```

Routing, fallback, observability, and tool calling all work the same way
regardless of which model backend you use.

### What's next

- **Production embeddings**: Persist the vector store with SQLite + `drift` so
  you don't re-embed on every cold start
- **More models**: Swap `gemini-3.7-flash` for `gemini-3.7-pro` for complex
  queries, or add a second on-device model for specialized tasks
- **Genkit flows**: Wrap the hybrid routing in a `defineFlow` to add
  observability, retries, and structured output
- **On-device RAG with Qdrant**: Replace the in-memory store with
  [Qdrant](https://qdrant.tech) for persistent, scalable vector search

### Resources

- [genkit_flutter_edge_ai on pub.dev](https://pub.dev/packages/genkit_flutter_edge_ai)
- [genkit_hybrid on pub.dev](https://pub.dev/packages/genkit_hybrid)
- [genkit on pub.dev](https://pub.dev/packages/genkit)
- [genkit_google_genai on pub.dev](https://pub.dev/packages/genkit_google_genai)
- [flutter_edge_ai on pub.dev](https://pub.dev/packages/flutter_edge_ai)
- [Genkit Dart documentation](https://genkit.dev)
