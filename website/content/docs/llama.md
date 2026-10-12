---
title: llama.cpp
description: Run local GGUF chat models with Flutter Edge AI and llamadart.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_llama` is an **unreleased contribution** providing optional
an inference engine powered by
[llamadart](https://pub.dev/packages/llamadart). The adapter registers through
core's existing provider APIs; core does not depend on it or bundle llama.cpp.

## Try the development package

Use Flutter **3.47.1 / Dart 3.13.1**. From the repository root:

```
cd packages/flutter_edge_ai_llama/example
python3 ../tool/fetch_test_model.py
flutter pub get
flutter run -d macos
```

Click **Choose model**, select `packages/flutter_edge_ai_llama/tool/fixtures/chat.gguf`,
and wait for **Ready**. Send “Say hello in one sentence.” The verified download
is about 145 MB; this small model is for trying the integration.

The example also has Android, iOS, Linux, Windows and Web runners. Native model
import copies a `.gguf` file into app-owned storage and restores its identity
after restart. The UI focuses on text chat, cancellation and a usable phone
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
    fileType: ModelFileType.binary,
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
a new chat when the context fills. Interrupted turns are discarded.

Core 2.2.1 restores installed models during initialization; conversation history
starts fresh. On Web, use `.fromNetwork(modelUrl)` with the assets and headers
described in the package guide.

This draft uses core 2.2.x and `ModelFileType.binary` for GGUF. Register the llama
provider alone for GGUF until core adds its dedicated file type. Migration to
core's 2.3.0 public engine libraries remains pending.

## Add the development package

The package is not on pub.dev yet. Use the example or a path dependency on
`packages/flutter_edge_ai_llama` in your clone. Core 2.2.1 is published and
requires no local-core override.
The [package setup guide](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/README.md#add-it-to-your-app)
shows the dependency YAML. Apple apps use iOS 16.4+ / macOS 14+ and the direct
`llamadart_llama_cpp_flutter: 0.0.21` SwiftPM companion.

## Select llama.cpp only

Put this in the **consuming application's** pubspec, or its workspace root:

```
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Dependency pubspec settings do not propagate to consumers. Without this
selection, llamadart bundles both llama.cpp and LiteRT-LM on supported native
targets. The monorepo configures llama.cpp for its own workspace tests; that
does not suppress another engine package's independently owned runtime.
Apple Flutter apps add `llamadart_llama_cpp_flutter 0.0.21` directly and enable
SwiftPM, as in this package's example. To keep an app llama.cpp only, omit the
separate LiteRT-LM engine and companion dependencies.

GGUF embeddings are deferred to a separate contribution against core's new
embedding SPI.

## Capabilities and qualification

The adapter implements tools, thinking, independent histories, native LoRA,
and projector-backed image/audio input. Each requires a
compatible model, template and runtime; unsupported combinations fail clearly.
Projector installation and
pairing remain application-owned. NPU and Web LoRA are unsupported.

Historical CPU chat/lifecycle evidence covers macOS, Linux/Windows GCE,
Android/iOS simulators and Web worker/Wasm. macOS also has model-specific
advanced feature and Metal evidence. Physical mobile devices, hardware WebGPU,
oldest supported OS versions and advanced features on other platforms remain
unqualified. See the
[support matrix](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md)
for exact models, platforms and remaining release checks.
