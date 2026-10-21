# GGUF text embeddings

Version 0.0.3 adds `LlamaEmbeddingBackend` to the existing llama engine package.
It requires core 2.5.0 and llamadart
0.15.1 with typed native overflow reporting. The core foundation is
[flutter_edge_ai #685](https://github.com/DenisovAV/flutter_edge_ai/pull/685);
the typed SDK error is [llamadart #1201](https://github.com/leehack/llamadart/pull/1201).
The manifest bounds the published SDK to `>=0.15.1 <0.15.2`.
Source qualification does not replace standalone hosted qualification. Do not
use a dependency override in production.

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
is applied. The load probe and every returned vector are checked for the
reported dimension, finite values and unit norm. An invalid load probe fails
with `EmbeddingLoadException`; invalid output during embedding throws
`EmbeddingEngineException`. The adapter never repairs vectors. The pinned Q8_0
fixture returns **768** values; its transformer width is **512**, which must
not be mistaken for output dimension.

The input budget is **1024 tokens including task prefix and special tokens**.
Context, batch and micro-batch are all configured to that size, so an entire
non-causal input fits one forward pass. Oversized input throws core's existing
`EmbeddingInputTooLongException`, retaining the SDK's effective limit and exact
count. It is never truncated; arbitrary inference errors remain engine errors.

Automatic requests reuse the current non-NPU embedder for the same installed
model. Repeating the GPU request that loaded a CPU fallback reuses that open
model, including across intervening CPU/automatic calls; it does not retry GPU
until a rebuild is needed or the model is closed. A CPU model loaded by an
unrelated CPU/automatic request does not suppress the first explicit GPU attempt.
Other explicit CPU/GPU switches replace the current model. The backend declares `{cpu, gpu}` through
`honouredBackends(spec)` and reports actual loaded placement. Unknown placement
is refused. Explicit GPU embeddings are refused on Android and iOS simulators
before SDK loading or the qualification probe. With fallback enabled, that refusal
allows one CPU attempt. Physical iOS and macOS retain GPU support; physical iOS
embedding execution still needs qualification.

Only an explicit GPU attempt that throws the SDK's `LlamaUnsupportedException`
may retry once on CPU. Its warning retains the first error; if CPU also fails,
the final load error includes both failures and preserves the CPU cause and stack.
Automatic requests retain SDK automatic selection and never retry load errors.
An automatic load that requested GPU layers but reports CPU emits one
release-visible warning per new successful load, except on Android and iOS
simulators, where llamadart's automatic placement is CPU by design. Core
continues to report an explicit GPU fallback once when it is loaded; reuse
repeats neither warning.
`activeBackend` always reports the verified loaded placement. Register
`LlamaEmbeddingBackend(backendFallback: false)` for exactly one load attempt;
an explicit placement mismatch fails with `EmbeddingLoadException`. Model
validation failures and worker initialization failures/timeouts are never retried
as GPU availability failures. Other model architectures and pooling conventions,
NPU, image/audio input and Web embeddings are refused. Browser registration does
not claim GGUF embedding files, so an unsupported install can fail its pre-check.
Inference remains independently available on the package's existing platforms.

Source qualification uses the pinned fixture in `tool/embedding_model.json`,
published llamadart 0.15.1 and the core source. macOS CPU/Metal and Linux/Windows
CPU embeddings have been measured. Android has an attributed Pixel 8a diagnostic;
iOS embeddings remain unqualified. See the [per-platform results](platforms.md#embedding-qualification-by-platform).
The dedicated source CI covers Linux/Windows CPU embeddings and Flutter 3.44
resolution. Hosted package qualification remains a separate release gate against
the published core.
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

Repository development uses the monorepo workspace and the example's
checkout-only core path override.
Resolve llamadart normally from pub.dev; no SDK override is needed. Source CI
stages core, the adapter and the app in a temporary directory and retains only
that core path override. This proves source compatibility; the hosted package
and minimum-SDK gates must independently resolve the published core without it.

From the package directory:

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
