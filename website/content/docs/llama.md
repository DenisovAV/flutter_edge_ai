---
title: llama.cpp
description: Run local GGUF chat and native EmbeddingGemma 2 text embeddings with Flutter Edge AI.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_llama` provides optional GGUF inference. Version 0.0.3 adds
native text embeddings powered by
[llamadart](https://pub.dev/packages/llamadart). The adapter registers through
core's existing provider APIs; core does not depend on it or bundle llama.cpp.

## Try the example

The package minimum is Flutter **3.44 / Dart 3.12**, with core **2.5.0+** and
published llamadart **0.15.1** with typed overflow reporting. Connector CI uses
Flutter 3.47.1 for reproducible checks. From the repository root:

```
cd packages/flutter_edge_ai_llama/example
python3 ../tool/fetch_test_model.py
flutter pub get
flutter run -d macos
```

Click **Choose model**, select `packages/flutter_edge_ai_llama/tool/fixtures/chat.gguf`,
and wait for **Ready**. Send “Say hello in one sentence.” The verified download
is about 145 MB; this small model is for trying the integration.

The example also has Android, iOS, Linux, Windows and Web runners. Android downloads from a GGUF URL. iOS and desktop copy a selected `.gguf`
into app-owned storage; the installed model restores after restart. The UI focuses on text chat, cancellation and a usable phone
layout. See the
[package README](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/README.md)
for the Web asset preparation and hosting headers.

## Stream a chat response

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LlamaEngineProvider()],
  );

  await FlutterEdgeAi.installModel(
    modelType: ModelType.general,
    fileType: ModelFileType.gguf,
  ).fromFile('/absolute/path/to/chat.gguf').install();

  final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
  try {
    final chat = await model.openChat(maxOutputTokens: 128);
    await chat.addQuery(Message.text(text: 'Hello!', isUser: true));
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is TextResponse) print(response.token);
    }
  } finally {
    await model.close();
  }
}
```

Replace the file path with your downloaded instruction-tuned GGUF.
`maxTokens` is the whole conversation context; `maxOutputTokens` limits one
response. Stop a stream with `await chat.session.stopGeneration()` and start
a new chat to clear history. Old complete turns are trimmed when the context fills. Interrupted turns are discarded.

Core restores installed models during initialization; conversation history
starts fresh. On Web, use `.fromNetwork(modelUrl)` with the assets and headers
described in the package guide.

The connector selects `ModelFileType.gguf` by its declared type. MediaPipe does not
claim that type. Engine imports and Web URL resolution use core's public engine
libraries. Core restores the paired LoRA after restart and refuses restoration
if its adapter is missing; Web LoRA execution remains unsupported.

## Add it to your app

Version 0.0.2 is published with llamadart 0.15.0 (0.0.1 used 0.13.1).
Version 0.0.3 adds native embeddings with llamadart 0.15.1; 0.0.4 changes only
the docs. This guide targets 0.0.4:

```
dependencies:
  flutter_edge_ai: ^2.5.4
  flutter_edge_ai_llama: ^0.0.4
```

Core 2.5.0+ supplies the embedding SPI and typed tool history.

The [package setup guide](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/README.md#add-it-to-your-app)
shows the dependency YAML. Apple apps use iOS 16.4+ / macOS 14+ and the direct
`llamadart_llama_cpp_flutter: 0.15.0` SwiftPM companion.

## Select llama.cpp only

Put this in the **consuming application's** pubspec, or its workspace root:

```
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Dependency settings do not propagate. llamadart 0.15.1 chooses llama.cpp only
when this connector or Flutter Edge AI LiteRT-LM is in the app graph. Keep the
explicit selection as defence in depth; selecting both LiteRT-LM owners is rejected. The monorepo configures llama.cpp for its own workspace tests; that
does not suppress another engine package's independently owned runtime.
Apple Flutter apps add `llamadart_llama_cpp_flutter 0.15.0` directly and enable
SwiftPM, as in this package's example. To keep an app llama.cpp only, omit the
separate LiteRT-LM engine and companion dependencies.

For an Apple workspace app on SDK 0.15.1, declare the companion directly in the
app member and put hook settings at the workspace root. Run `flutter pub get`
from the root, then build from the app directory. The hook now discovers the
member's companion. Keep companion choices consistent across app members using
llamadart; ambiguous or mixed Flutter/Dart setups warn and retain hook-bundled assets.
See the [workspace setup and qualification scope](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md#apple-workspaces).

Native EmbeddingGemma 2 GGUF text embeddings register through core's embedding
SPI as `LlamaEmbeddingBackend` in this same engine package. The dedicated
`flutter_edge_ai_embeddings` package remains tokenizer-only: GGUF carries its
own tokenizer. Version 0.0.3 requires the core 2.5.0 SPI and llamadart
0.15.1. Use separate GGUF and LiteRT RAG profile IDs; matching dimensions do
not make their vectors interchangeable.
See the [embedding design and qualification](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/embeddings.md).
Embedding execution has been measured on macOS CPU/Metal and Linux/Windows CPU.
Android has a maintainer Pixel 8a CPU/Vulkan diagnostic; full Android qualification
and iOS embedding execution remain unqualified. See the
[per-platform embedding evidence](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md#embedding-qualification-by-platform).
Explicit GPU embeddings on Android (every device) and on iOS simulators fall back to CPU by
default. Register `LlamaEmbeddingBackend(backendFallback: false)` to refuse
those requests before loading. Automatic requests keep SDK automatic selection.
Media and Web embeddings remain unavailable in the initial profile.

## Capabilities and qualification

The adapter implements tools, thinking, independent histories, native LoRA,
and projector-backed image/audio input. Each requires a
compatible model, template and runtime; unsupported combinations fail clearly.
Projector installation and
pairing remain application-owned. NPU and Web LoRA are unsupported.

CI covers CPU chat/lifecycle on desktop, Android/iOS simulators and Web worker/Wasm.
Physical Android ARM64 and iOS devices, hardware WebGPU, native GPUs, oldest
supported OS versions and advanced model/media/LoRA combinations still need qualification.
App Store submission and mixed Apple workspace configurations are unvalidated.
Web installation buffers a byte array; use models below about 2 GB and avoid streaming OPFS mode. See the
[support matrix](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md)
for setup, capability limits and qualification.

With llamadart 0.15.1, adding `flutter_edge_ai_litertlm` keeps the SDK on
llama.cpp automatically. Retain the root `[llama_cpp]` selection as defence in
depth; explicitly selecting both LiteRT-LM owners fails with an actionable error.
On Apple the direct `llamadart_llama_cpp_flutter` companion dependency is required too. From
`flutter_edge_ai_litertlm` 1.19.0 LiteRT-LM keeps SwiftPM on as well, and both
native libraries load in one app; running both engines' models in one app is
not qualified. Web LoRA is not wired
by this connector and is rejected, even on a bridge that supports adapters.
The package README provides Web asset setup using helpers included in its archive.
