---
title: Genkit
description: Use flutter_edge_ai through Genkit — on-device model/embedder provider and hybrid on-device/cloud routing.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

[Genkit](https://pub.dev/packages/genkit) is Google's open-source framework
for building AI-powered features in Dart and Flutter. Two packages bridge
flutter_edge_ai into Genkit — one wraps the on-device runtime as a standard
Genkit provider, the other adds hybrid routing so you can combine on-device
and cloud models behind a single `ai.generate` call.

## genkit_flutter_edge_ai

Wraps flutter_edge_ai as a Genkit model and embedder provider. Once registered,
streaming, tool use, embeddings and prompt templates go through the standard
Genkit API; what a request can use depends on the installed model (see the
notes below).

### Add to pubspec.yaml

```
dependencies:
  genkit: ^1.0.0                  # the framework itself — every snippet below uses it
  genkit_flutter_edge_ai: ^0.10.0
  flutter_edge_ai: ^2.4.0
  # Add the inference engine(s) you need:
  flutter_edge_ai_litertlm: ^1.14.0   # .litertlm models (mobile + desktop + web) + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: ^1.2.2  # .task / .bin models (mobile + web)
  # Optional — tokenizers for .tflite / .onnx embedding models (an EmbeddingGemma 2
  # .litertlm needs none; the backend is flutter_edge_ai_litertlm above):
  flutter_edge_ai_embeddings: ^2.3.0
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

// For a .litertlm model pass fileType: ModelFileType.litertlm to
// installModel(); it defaults to ModelFileType.task, which routes the model to
// MediaPipe. FlutterEdgeAiModelConfig.fileType does not affect routing.

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

New apps should prefer `.litertlm`: Google's MediaPipe LLM Inference API is
maintenance-only, its `.task` models do not load on the iOS GPU, and it has no
desktop.

Model and embedder ids are `flutter-edge-ai/<name>` (they were
`flutter-gemma/<name>`), and 0.7.0 drops the old `genkit_flutter_gemma` Dart
names — `dart fix --apply` renames them.

### Generate text

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Hello!',
);
final reason = response.finishReason;
if (reason != FinishReason.stop &&
    reason != FinishReason.length &&
    reason != FinishReason.unknown) {
  throw response.cause ??
      StateError(response.finishMessage ?? 'The model stopped: $reason');
}
print(response.text);
```

In genkit 1.0 `ai.generate` does not throw when the generation fails. It
returns a result whose `finishReason` is `failed` (or `aborted` for a cancel),
with the error in `error` and the original exception in `cause`. An engine you
forgot to register, an invalid option and a cancel all arrive this way, so check
the result before you show its text: without the check a failure prints an
empty line.

### Stream text

```dart
final stream = ai.generateStream(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Write a short story.',
);

await for (final chunk in stream) {
  stdout.write(chunk.text);
}
// A failure ends the stream normally; the result says what happened.
final result = await stream.onResult; // check finishReason as above
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

Texts are embedded as search queries. EmbeddingGemma prefixes queries and
documents differently, so embed what you index as documents:

```dart
final documentVectors = await ai.embed(
  embedder: flutterEdgeAi.embedder('embedding-gemma-300m'),
  documents: chunks,
  options: FlutterEdgeAiEmbedConfig(taskType: 'retrievalDocument'),
);
```

Index with `retrievalDocument` and search with the default
`retrievalQuery`. The embedder runs the model `installEmbedder()` made active,
EmbeddingGemma 2 included; see [Embeddings & RAG](/docs/embeddings-and-rag). It
takes text only: a document with no text part is an
`INVALID_ARGUMENT`. Since 0.9.1 it resolves the active embedder again for
every request, so it follows a model core replaced or closed in between.

### Configuration options

Pass `FlutterEdgeAiModelOptions` to tune inference:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Hello!',
  config: FlutterEdgeAiModelOptions(
    maxTokens: 2048,                // context window (input + output), not reply length
    maxOutputTokens: 256,           // cap on the reply (every engine except MediaPipe)
    temperature: 0.5,
    topK: 40,
    supportImage: true,
    supportAudio: true,             // audio input
    enableThinking: true,           // reasoning arrives as a ReasoningPart
    toolChoice: 'auto',             // tool calling mode: 'auto' / 'required' / 'none'
    // Optional per-component backend ('cpu'/'gpu'/'npu'):
    preferredBackend: 'gpu',        // text decoder
    // preferredVisionBackend / preferredAudioBackend: unset, each encoder
    // follows the bundle (its backend_constraint, else the NPU it is compiled
    // for, else CPU); set one only where the section allows it.
  ),
);
```

With `enableThinking: true` the reasoning comes before the reply as a
`ReasoningPart` (in `response.message?.content`, or each streamed
`chunk.content`); read it with `part.reasoning`. `response.text` holds the reply
alone.

Leave `temperature`, `topK` and `topP` unset to get the model's own sampler: the
one a `.litertlm` file ships, else the defaults its family publishes. On
`.litertlm` the first request after a model loads fixes the sampler for that
loaded model (LiteRT-LM#2080), so a later request with different values needs
the model reloaded.

Prefer Genkit's standard top-level parameter — `ai.generate(toolChoice: .none)`
— which takes **precedence** over the `toolChoice` config field above (kept as a
legacy fallback). Write `.none`, not `ToolChoice.none`: genkit 1.0 and
`flutter_edge_ai` both export a `ToolChoice`, so with both imported unprefixed
the full name is an `ambiguous_import` error. Either way: `'auto'` lets the model decide, `'required'` forces
a tool call, `'none'` forbids one. An unrecognized value is an
`INVALID_ARGUMENT` error rather than a quiet fallback to `'auto'`.

<Info>

The plugin does **not** manage model installation. Call
`FlutterEdgeAi.installModel()` (and `FlutterEdgeAi.installEmbedder()` for
embeddings) before using the plugin; without one a request fails with
`UNAVAILABLE`, which a `genkit_hybrid` router treats as a reason to fall back.
See [Getting Started](/docs/getting-started).

Every configured model name runs the model that is active in flutter_edge_ai;
the name is a label. The names share one queue, and each request asks
flutter_edge_ai for the active model, so a newly installed model is picked up
by the next request. Set
`supportsTools: false` or `supportsMedia: false` on a
`FlutterEdgeAiModelConfig` whose model takes no tools or media: its `supports`
metadata says so, and a request that needs them fails with `UNIMPLEMENTED`
instead of reaching a model that would ignore them. Options are checked before
anything loads, so a bad value, a `maxOutputTokens` larger than `maxTokens`
among them, is an `INVALID_ARGUMENT`. An engine that cannot do what was asked
on this platform is `UNIMPLEMENTED`, which `genkit_hybrid` hands to its next
branch. An installed model the app cannot run (no engine registered for it) is
`FAILED_PRECONDITION`, which no router hides.

</Info>

### Structured (JSON) output

The plugin advertises `output: ['text', 'json']`. Genkit asks for constrained
output whenever you pass an `outputSchema`. No on-device engine can constrain
decoding to a schema, so the plugin writes the schema into the prompt as
instructions, the way Genkit's `simulateConstrainedGeneration()` middleware
does (adding the middleware as well is harmless: the schema is written once).
It returns the raw model text and Genkit's `extractJson` populates
`response.output`. Pass `outputConstrained: false` to leave the prompt alone.

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-3-1b'),
  prompt: 'Give me a pancake recipe.',
  outputSchema: Recipe.$schema, // any @Schema()-annotated type
);

final Recipe? recipe = response.output;
```

Genkit does not check the reply against the schema, so validate
`response.output` yourself. What you get depends on the reply:

- **No JSON at all** (or an object cut off mid-way): the result still finishes
  with `FinishReason.stop`, `response.output` is null and `response.error` says
  why.
- **A JSON object with the wrong fields**: `response.output` is not null and
  `response.error` is null. A missing field reads as null, and reading a field
  of the wrong type throws.
- **A bare number, string or array** — prose such as "Serves 4 people" is
  enough, because the `4` is extracted: `ai.generate` throws a `TypeError`
  instead of returning a result.

The schema goes into the first system message, or into the last user message
when there is none. `FlutterEdgeAiModelOptions.systemInstruction` replaces
system messages; the plugin keeps the schema and appends it to that
instruction.

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
model's context window) minus the response headroom: 256 tokens, or the
request's `maxOutputTokens` when that is larger. A requested output schema is
held back as well, since it is written into the prompt after the trimmer runs.

## genkit_hybrid

Provider-agnostic hybrid routing for Genkit. Combine any two existing Genkit
models — on-device, cloud, or anything else — behind one routing policy. The
result is an ordinary `Model`, so your app still calls a single `ai.generate`.

`genkit_hybrid` depends only on `genkit` — it has no dependency on
flutter_edge_ai and works with **any** pair of Genkit models.

### Add to pubspec.yaml

```
dependencies:
  genkit_hybrid: ^0.3.1
  genkit: ^1.0.0
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
with `UNAVAILABLE`, `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED` or `INTERNAL` —
or on `UNIMPLEMENTED`: a capability one model lacks (tools, images, audio on
this platform) another branch's model may have. Permanent errors —
`INVALID_ARGUMENT`, `PERMISSION_DENIED`, `UNAUTHENTICATED`,
`FAILED_PRECONDITION`, `NOT_FOUND` — propagate immediately, since they would
fail the same way on every branch. A `GenkitException` thrown without an
explicit status defaults to `INTERNAL`, so it *is* retried. After a cancel no
other branch is tried: the error of the branch that was running is the one
reported.

The error that propagates does not leave `ai.generate` as an exception. In
genkit 1.0 a failed generation comes back as a result with
`finishReason: FinishReason.failed`, the error in `error` and the original
exception in `cause`; `ai.generateStream` ends normally with that result in
`onResult`. A cancel or a `maxTurns` overrun ends the same way with
`FinishReason.aborted`, often with no `cause`; `error` is set in both cases.
A cloud branch can also stop on its own terms without any error:
`genkit_google_genai` reports a safety block as `FinishReason.blocked` and a
reason it does not know as `FinishReason.other`. Treat every finish other than
`stop`, `length` and `unknown` as a failure:

```dart
await for (final chunk in stream) { /* ... */ }
final result = await stream.onResult;
final reason = result.finishReason;
if (reason != FinishReason.stop &&
    reason != FinishReason.length &&
    reason != FinishReason.unknown) {
  throw result.cause ??
      StateError(result.finishMessage ?? 'The model stopped: $reason');
}
```

During **streaming** the same policy applies plus a hard cut-off: fallback is
possible only before the first token. Once a branch has emitted a chunk, any
later failure propagates — a partially delivered response cannot be silently
re-routed.

### Escalate on a quality check with `cascadeModel`

`cascadeModel` is a `Model` (not a strategy): it runs branches in order and
escalates to the next one only when your `accept` predicate rejects the
response — "try the cheap on-device model; go to the cloud only if the answer
isn't good enough". `accept` is any check you like (a length or regex test, a
JSON-parses check) and may be async, e.g. an LLM-as-judge. A request cancelled
while an async `accept` runs ends with the cancellation, whatever the verdict.

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
can combine `gemini-2.5-flash` (cloud) with a model from any other Genkit
plugin.

</Info>
