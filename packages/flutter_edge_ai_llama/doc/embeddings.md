# GGUF text embeddings

This draft adds `LlamaEmbeddingBackend` to the existing llama engine package.
It requires the core 2.5.0 embedding SPI and the next llamadart patch's typed
native overflow error. The core foundation is [flutter_edge_ai #685](https://github.com/DenisovAV/flutter_edge_ai/pull/685);
the typed SDK error is [llamadart #1201](https://github.com/leehack/llamadart/pull/1201).
Those releases are prerequisites; the manifest's
`>=0.15.1 <0.15.2` bound is a proposed release target, not a published or
hosted-qualified SDK pin. Do not use a dependency override in production.

`flutter_edge_ai_embeddings` remains a tokenizer implementation package. GGUF
carries its own tokenizer; it needs no dependency on that package. Core owns
installation, hosting, queuing, cancellation and close; llamadart owns execution.
The embedding runtime uses its own model/context, independently of chat.

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: const [LlamaEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromFile('/models/embeddinggemma-2-Q8_0.gguf')
    .install();
final model = await FlutterEdgeAi.getActiveEmbedder(
  preferredBackend: PreferredBackend.cpu,
);
try {
  final vector = await model.embed(
    EmbeddingInput.text('How can I brew coffee?'),
    taskType: TaskType.retrievalQuery,
  );
  print(vector.length);
} finally {
  await model.close();
}
```

Imports are `package:flutter_edge_ai/flutter_edge_ai.dart` and
`package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart`. An opaque model URL
needs an explicit `.gguf` installed filename. Do not install an external
GGUF tokenizer. Register `LlamaEngineProvider` too when the app also uses chat.

## Qualified profile

The initial native text profile checks `gemma-embedding2` architecture and mean
pooling. It uses all nine core `TaskType` prefixes, the model's own tokenizer and
output projection, and SDK L2 normalization. No second pooling or normalization
is applied. The pinned Q8_0 fixture returns **768** values; its transformer width
is **512**, which must not be mistaken for output dimension.

The input budget is **1024 tokens including task prefix and special tokens**.
Context, batch and micro-batch are all configured to that size, so an entire
non-causal input fits one forward pass. Oversized input throws core's existing
`EmbeddingInputTooLongException`, retaining the SDK's effective limit and exact
count. It is never truncated; arbitrary inference errors remain engine errors.

CPU, GPU and automatic requests have separate core cache keys. Actual backend
reporting comes from the loaded SDK; unknown stays null. An explicit GPU request
that loads CPU is refused. Other model architectures and pooling conventions,
NPU, image/audio input and Web embeddings are refused. Browser registration does
not claim GGUF embedding files, so an unsupported install can fail its pre-check.
Inference remains independently available on the package's existing platforms.

Local candidate evidence uses the pinned fixture in `tool/embedding_model.json`,
macOS arm64 CPU and Metal, and the local typed-overflow SDK branch. Hosted package
qualification, Linux/Windows and mobile embedding execution remain release gates.
Other EG2 quantizations need their own numerical qualification.

## RAG identity and lifecycle

Use the existing RAG `FlutterEdgeAiActiveEmbedder` with an explicit profile ID.
Give GGUF a different ID from LiteRT, even when both return 768 values. Include
weights/hash, quantization, task-prefix convention, pooling, normalization and
any backend distinction your index relies on. Rebuild an index when this identity
changes. The llama package does not own a `RagIndex` or vector store.

`embedAll` uses core's bounded queue. Cancellation stops sending and discards
partial results; already dispatched work can finish. Close waits for in-flight
work and frees the SDK runtime. There is no additional cancellation or lifecycle
API in this adapter.

## Reproducible qualification

For source-only development before publication, temporarily override `llamadart`
to the #1201 checkout in the workspace root's `pubspec_overrides.yaml`. Append the
same override to the example's existing checkout-only override file, retaining
its core path entry, then run `flutter pub get`. Remove only these temporary SDK
overrides after qualification; never commit them or use them as hosted evidence.

After the prerequisite sources or releases resolve, from the package directory:

```sh
python3 tool/verify_embeddings.py --model-path /absolute/embeddinggemma-2-Q8_0.gguf --backend cpu
python3 tool/verify_embeddings.py --model-path /absolute/embeddinggemma-2-Q8_0.gguf --backend gpu
```

The runner checks size/SHA-256, uses canonical `flutter test -d <desktop>` and
requires the named test's machine-reported success. On macOS the sandbox remains
enabled: a loopback server lets core install a verified app-owned model copy.
The test covers dimension, finite unit vectors, retrieval ranking, all task
prefixes, exact overflow, cancellation, refusal preserving a cached model and
three close/reload cycles; the GPU lane also switches CPU → GPU → automatic.
No fixture means no qualification. The model is not included in the archive.

Multimodal GGUF embeddings remain a later contribution using the same
`EmbeddingInput` API, an app-owned projector and embedding-specific capability
probes. Web also needs typed overflow transport and real browser qualification.
