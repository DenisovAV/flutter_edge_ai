---
title: llama.cpp
description: GGUF inference and embeddings through llamadart, with explicit runtime packaging and platform qualification.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_llama` is an **unreleased contribution** providing optional
inference and embedding engines powered by
[llamadart](https://pub.dev/packages/llamadart). The adapter registers through
core's existing provider APIs; core does not depend on it or bundle llama.cpp.

## Try the development package

Use Flutter **3.47.1 / Dart 3.13.1**. From the repository root:

```sh
cd packages/flutter_edge_ai_llama/example
flutter pub get
flutter run -d macos
```

The example also has Android, iOS, Linux, Windows and Web runners. Native model
import copies a `.gguf` file into app-owned storage and restores its identity
after restart. The UI focuses on text chat, cancellation and a usable phone
layout. See the
[package README](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/README.md)
for the Web asset preparation and hosting headers.

## Register providers

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [LlamaEngineProvider()],
  embeddingBackends: const [LlamaEmbeddingProvider()],
);
await restoreInstalledLlamaModel();
```

Core 2.1.3 has no dedicated GGUF file type. Install a `.gguf` with
`ModelFileType.binary`; the adapter recognizes its GGUF extension and declines
other binary formats. Imported-file restoration and Web active identity have
documented compatibility shims. The adapter currently pins core **2.1.3** and
llamadart **0.11.1** until public extension APIs replace those shims.

## Select llama.cpp only

Put this in the **consuming application's** pubspec, or its workspace root:

```yaml
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

## Capabilities and qualification

The adapter implements tools, thinking, independent histories, native LoRA,
GGUF embeddings and projector-backed image/audio input. Each requires a
compatible model, template and runtime; unsupported combinations fail clearly.
GGUF embedding models use their embedded tokenizer, though core's installation
API currently still requires a tokenizer companion. Projector installation and
pairing remain application-owned. NPU and Web LoRA are unsupported.

Historical CPU chat/lifecycle evidence covers macOS, Linux/Windows GCE,
Android/iOS simulators and Web worker/Wasm. macOS also has model-specific
advanced feature and Metal evidence. Physical mobile devices, hardware WebGPU,
oldest supported OS versions and advanced features on other platforms remain
unqualified. See the
[support matrix](https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai_llama/doc/platforms.md)
for exact models, platforms and remaining release checks.
