# Flutter Edge AI core

This directory contains the engine-independent contracts and orchestration used
by `flutter_edge_ai`. The core package owns model installation, lifecycle,
registries, shared message/value types, embedding orchestration, and the vector
store interface. Concrete inference engines, embedding/tokenizer
implementations, speech backends, and vector stores stay in opt-in packages.

## Dependency direction

```text
application
  ├─ flutter_edge_ai_litertlm / mediapipe / onnx / built_in_ai
  ├─ flutter_edge_ai_embeddings
  ├─ flutter_edge_ai_qdrant / sqlite
  ├─ flutter_edge_ai_speech / agent
  └─ flutter_edge_ai (core contracts and registries)
```

Satellites normally depend only on core; core never imports a satellite.
The intentional exception is `flutter_edge_ai_speech` →
`flutter_edge_ai_litertlm`: speech imports `LiteRtBindings` directly and uses
the native bundle litertlm owns. Applications select registered implementations
explicitly in `FlutterEdgeAi.initialize(...)`.

## Directory map

```text
lib/core/
├─ api/              # FlutterEdgeAi facade and installation builders
├─ domain/           # ModelSource and platform-neutral value types
├─ registry/         # inference, embedding, tokenizer, speech, skill, HF probes
├─ embedding/        # shared worker, pooling, cache, and tokenizer adapter
├─ services/         # storage and vector-store contracts
├─ infrastructure/   # core-owned service implementations
├─ handlers/         # Network/Asset/Bundled/File source installation
├─ lifecycle/        # CloseNotifier ownership seam
├─ model_management/ # persisted model specs and platform managers
└─ parsing/           # function-call wire formats and response parsing
```

## Initialization

Core registers no inference engine, embedding backend/tokenizer, speech
backend, skill executor, Hugging Face resolver, or vector store by default.
Register only the packages the application ships:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
```

Registries use a probe chain: providers answer `canHandle(spec)`, then priority
and registration order choose the implementation. A missing implementation
fails loudly and names the opt-in package to add.

## Installing and using a model

`ModelFileType` selects the engine. It is not inferred from a filename, and
`installModel` defaults to `task`, so declare non-MediaPipe formats explicitly.

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
).fromNetwork('https://example.com/gemma-4.litertlm').install();

final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession(maxOutputTokens: 256);
try {
  await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
  final response = await session.getResponse();
  print(response);
} finally {
  await session.close();
  await model.close();
}
```

Installation sources are the sealed `NetworkSource`, `AssetSource`,
`BundledSource`, and `FileSource` variants exposed through the builder methods
`fromNetwork`, `fromAsset`, `fromBundled`, and `fromFile`. ONNX Runtime GenAI
installs are directories and use their engine's Hugging Face resolver rather
than the single-file network path.

## Ownership boundaries

- Core owns provider selection and the singleton active-model lifecycle.
- Engines are factories and return models that notify core when they close.
- `EmbedderCache` owns cached embedding instances and serializes access.
- `UnconfiguredVectorStore` is the default sentinel; a RAG package supplies the
  real `VectorStoreRepository` during initialization.
- Tokenizer implementations live in `flutter_edge_ai_embeddings`; only their
  provider contract and adapter live here.
- Web storage is selected with `WebStorageMode`; compatibility storage and
  channel identifiers may intentionally retain the old `flutter_gemma` name.

## Testing changes in core

Run package tests from the repository-provided runner so fixture-relative tests
use the same working directories as CI:

```bash
flutter analyze packages/
tool/test_all.sh
```

Do not run `flutter test packages/flutter_edge_ai` from the workspace root; it
uses the wrong working directory for package-relative fixtures.
