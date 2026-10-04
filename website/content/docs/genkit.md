---
title: Genkit
description: Use flutter_edge_ai through Genkit — on-device model/embedder provider and hybrid on-device/cloud routing.
image: https://flutteredge.ai/images/og-image.png
---

[Genkit](https://pub.dev/packages/genkit) is Google's open-source framework
for building AI-powered features in Dart and Flutter. Two packages bridge
flutter_edge_ai into Genkit — one wraps the on-device runtime as a standard
Genkit provider, the other adds hybrid routing so you can combine on-device
and cloud models behind a single `ai.generate` call.

## genkit_flutter_edge_ai

Wraps flutter_edge_ai as a Genkit model and embedder provider. Once registered,
every Genkit feature (streaming, tool use, embeddings, prompt templates) works
with the on-device model exactly as it would with any cloud provider.

### Add to pubspec.yaml

```
dependencies:
  genkit: ^0.16.0                  # the framework itself — every snippet below uses it
  genkit_flutter_edge_ai: ^0.7.0
  flutter_edge_ai: ^2.0.0
  # Add the inference engine(s) you need:
  flutter_edge_ai_litertlm: ^1.8.7   # .litertlm models (mobile + desktop + web) + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: ^1.0.9  # .task / .bin models (mobile + web)
  # Optional — for embeddings (needs a backend, e.g. flutter_edge_ai_litertlm above):
  flutter_edge_ai_embeddings: ^2.2.2
```

### Setup

Register the engine packages in `FlutterEdgeAi.initialize()`, install your
model, then create a `Genkit` instance with the plugin:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

// 1. Register providers (call once in main).
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()], // flutter_edge_ai_litertlm
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
);

// 2. Install the model (host app responsibility).
await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
    .fromAsset('assets/gemma-3-1b-it-int4.task')
    .install();

// For a .litertlm model declare the type in BOTH places — installModel(
// fileType: ModelFileType.litertlm) and FlutterEdgeAiModelConfig(fileType: ...).
// Both default to ModelFileType.task, which routes the model to MediaPipe.

// 3. Create a Genkit instance with the plugin.
final ai = Genkit(plugins: [
  GenkitFlutterEdgeAiPlugin(
    models: [
      FlutterEdgeAiModelConfig(
        name: 'gemma-3-1b',
        modelType: ModelType.gemmaIt,
      ),
    ],
    embedders: [
      FlutterEdgeAiEmbedderConfig(name: 'embedding-gemma-300m'),
    ],
  ),
]);
```

Model and embedder ids are `flutter-edge-ai/<name>` (they were
`flutter-gemma/<name>`), and 0.7.0 drops the old `genkit_flutter_gemma` Dart
names — `dart fix --apply` renames them.

### Generate text

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Hello!',
);
print(response.text);
```

### Stream text

```dart
final stream = ai.generateStream(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Write a short story.',
);

await for (final chunk in stream) {
  stdout.write(chunk.text);
}
```

### Embeddings

```dart
final embeddings = await ai.embed(
  embedder: flutterEdgeAi.embedder('embedding-gemma-300m'),
  documents: [
    DocumentData(content: [TextPart(text: 'Flutter is a UI toolkit.')]),
  ],
);
```

<Warning>
The Genkit embedder always embeds with flutter_edge_ai's default
`TaskType.retrievalQuery` prefix — `FlutterEdgeAiEmbedConfig` has no `taskType`
option. For RAG **indexing**, where documents must be embedded with
`TaskType.retrievalDocument`, call
`FlutterEdgeAi.getActiveEmbedder().generateEmbeddings(..., taskType: ...)`
directly. Mixing the two prefixes is the cross-prefix drift that #264 fixed at
the core level. See [Embeddings & RAG](/docs/embeddings-and-rag).
</Warning>

### Configuration options

Pass `FlutterEdgeAiModelOptions` to tune inference:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Hello!',
  config: FlutterEdgeAiModelOptions(
    maxTokens: 2048,                // context window (input + output), not reply length
    temperature: 0.5,
    topK: 40,
    supportImage: true,
    toolChoice: 'auto',             // tool calling mode: 'auto' / 'required' / 'none'
    // Optional per-component backend ('cpu'/'gpu'/'npu'):
    preferredBackend: 'gpu',        // text decoder
    preferredAudioBackend: 'gpu',   // audio encoder (~2x on Metal; defaults to CPU)
    // preferredVisionBackend defaults to CPU (Metal/WebGPU can't run its ops).
  ),
);
```

Prefer Genkit's standard top-level parameter — `ai.generate(toolChoice: 'none')`
— which takes **precedence** over the `toolChoice` config field above (kept as a
legacy fallback). Either way: `'auto'` lets the model decide, `'required'` forces
a tool call, `'none'` forbids one. An unrecognized value throws
`INVALID_ARGUMENT` rather than quietly falling back to `'auto'`.

<Info>
The plugin does **not** manage model installation. Call
`FlutterEdgeAi.installModel()` (and `FlutterEdgeAi.installEmbedder()` for
embeddings) before using the plugin. See [Getting Started](/docs/getting-started).
</Info>

### Structured (JSON) output

The plugin advertises `output: ['text', 'json']`. On-device Gemma has no native
schema-constrained decoder, so Genkit's instruction-injection fallback drives
JSON output — the plugin returns raw model text and Genkit's `extractJson`
populates `response.output`. Pass an `outputSchema` and read the parsed object:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Give me a pancake recipe.',
  outputSchema: Recipe.$schema, // any @Schema()-annotated type
);

final Recipe? recipe = response.output;
```

### Context-window trimming

On-device models run with a fixed, small context window (`maxTokens` — 1024 for
most `.litertlm` models). A long multi-turn chat overflows it and the native
runtime fails to allocate the KV cache mid-generation. `trimContext()` is a
middleware that drops the oldest **non-system** turns before each model call,
always keeping every system message and the most recent message:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Continue our conversation…',
  messages: longHistory,
  use: [trimContext(maxInputTokens: 800)],
);
```

With no arguments the budget is derived from the request's `maxTokens` (the
model's context window) minus 256 tokens of response headroom.

## genkit_hybrid

Provider-agnostic hybrid routing for Genkit. Combine any two existing Genkit
models — on-device, cloud, or anything else — behind one routing policy. The
result is an ordinary `Model`, so your app still calls a single `ai.generate`.

`genkit_hybrid` depends only on `genkit` — it has no dependency on
flutter_edge_ai and works with **any** pair of Genkit models.

### Add to pubspec.yaml

```
dependencies:
  genkit_hybrid: ^0.2.2
  genkit: ^0.16.0
```

### Basic usage

```dart
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

final ai = Genkit();

// onDeviceModel and cloudModel are ordinary Genkit Models you already have.
final smart = hybridModelOnDeviceCloud(
  onDevice: onDeviceModel,
  cloud: cloudModel,
  strategy: ConnectivityStrategy(
    isOnline: () => connectivity.isOnline,
    online: kCloud,
    offline: kOnDevice,
  ),
);

// A hybrid model is an ordinary Model — register it, then use it like any other.
ai.registry.register(smart);

final response = await ai.generate(model: smart, prompt: 'Hello!');
```

### Routing strategies

| Strategy | Routes on |
|---|---|
| `PreRoutingStrategy(fn)` | your own function (privacy, cost, user tier…) |
| `FallbackStrategy(order)` | fixed priority order — `kOnDevice` first or `kCloud` first |
| `ConnectivityStrategy(...)` | network availability |
| `InputSizeStrategy(...)` | prompt length |
| `CapabilityStrategy(supports: {...})` | the capabilities a request needs — vision / audio / tools / json — routing to branches that declare them |
| `CostStrategy(budgetAvailable:, premium:, cheap:)` | a budget signal — the premium branch while the budget holds, the cheap branch once it's spent |
| `FirstMatch([...])` | first child strategy that decides (chain of rules) |
| `WithFallback(s, fallbackOrder: order)` | any strategy's pick + a guaranteed fallback tail |

### Prefer on-device, fall back to cloud

```dart
hybridModelOnDeviceCloud(
  onDevice: onDeviceModel,
  cloud: cloudModel,
  strategy: FallbackStrategy([kOnDevice, kCloud]),
);
```

### Chain multiple rules

```dart
hybridModelOnDeviceCloud(
  onDevice: onDeviceModel,
  cloud: cloudModel,
  strategy: WithFallback(
    FirstMatch([
      PreRoutingStrategy((c) => userOptedOutOfCloud ? kOnDevice : ''),
      ConnectivityStrategy(
        isOnline: () => net.isOnline,
        online: kCloud,
        offline: kOnDevice,
      ),
    ]),
    fallbackOrder: [kOnDevice],
  ),
);
```

### Route by required capabilities

`CapabilityStrategy` inspects what the request actually needs — an image or
audio part, tool definitions, or JSON output — and keeps only the branches that
declare those capabilities (or `[]` when none qualifies, so compose it with
`WithFallback`). Capabilities are declared explicitly per branch; nothing is
inferred from model metadata.

```dart
final smart = hybridModel(
  branches: {'onDevice': onDeviceModel, 'cloud': cloudModel},
  strategy: WithFallback(
    CapabilityStrategy(supports: {
      'onDevice': {},                                   // text only
      'cloud': {ModelCapability.vision, ModelCapability.tools},
    }),
    fallbackOrder: ['cloud'],
  ),
);
```

A plain-text request can use either branch; a request carrying an image or tool
definitions is routed to `cloud`, the only branch that declares those
capabilities.

### Budget-gate a paid branch

`CostStrategy` sends traffic to a premium branch only while an app-supplied
budget signal holds, and falls back to the cheap branch once it's spent. Your
app owns the accounting (running spend, a daily cap, a quota) and reduces it to
one `bool` — the package depends on no billing SDK.

```dart
hybridModel(
  branches: {'onDevice': onDeviceModel, 'cloud': cloudModel},
  strategy: CostStrategy(
    budgetAvailable: () => spend.today < dailyCap,
    premium: 'cloud',
    cheap: 'onDevice',
  ),
);
```

### Error policy and fallback

Fallback is error-driven: the strategy picks an order, and the next branch is
tried only when the current one **throws**, and only on a transient failure —
any non-`GenkitException` error (network, timeout, OOM), or a `GenkitException`
with `UNAVAILABLE`, `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED` or `INTERNAL`.
Permanent errors — `INVALID_ARGUMENT`, `PERMISSION_DENIED`, `UNAUTHENTICATED`,
`FAILED_PRECONDITION`, `NOT_FOUND` — propagate immediately, since they would
fail the same way on every branch. A `GenkitException` thrown without an
explicit status defaults to `INTERNAL`, so it *is* retried.

During **streaming** the same policy applies plus a hard cut-off: fallback is
possible only before the first token. Once a branch has emitted a chunk, any
later failure propagates — a partially delivered response cannot be silently
re-routed.

### Escalate on a quality check with `cascadeModel`

`cascadeModel` is a `Model` (not a strategy): it runs branches in order and
escalates to the next one only when your `accept` predicate rejects the
response — "try the cheap on-device model; go to the cloud only if the answer
isn't good enough". `accept` is any check you like (a length or regex test, a
JSON-parses check) and may be async, e.g. an LLM-as-judge.

```dart
import 'package:genkit_hybrid/genkit_hybrid.dart';

final smart = cascadeModel(
  branches: {'onDevice': onDeviceModel, 'cloud': cloudModel},
  order: ['onDevice', 'cloud'],
  accept: (r) => r.text.trim().length > 20,
);

final response = await ai.generate(model: smart, prompt: 'Explain quantum tunnelling.');
```

> **`cascadeModel` is non-streaming in v1.** A quality verdict needs the whole
> response, and a streamed response can't be un-sent, so a streaming request is
> run non-streamed and the accepted response is emitted as a single final chunk.

<Info>
`genkit_hybrid` works with **any** Genkit models, not just flutter_edge_ai. You
can combine `gemini-2.5-flash` (cloud) with a local Ollama model, or any other
pair that Genkit supports.
</Info>
