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
  genkit_flutter_edge_ai: ^0.11.0
  flutter_edge_ai: ^2.5.1
  # Add the inference engine(s) you need:
  flutter_edge_ai_litertlm: ^1.17.0   # .litertlm models (mobile + desktop + web) + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: ^1.2.3  # .task / .bin models (mobile + web)
  # Optional — tokenizers for .tflite / .onnx embedding models (an EmbeddingGemma 2
  # .litertlm needs none; the backend is flutter_edge_ai_litertlm above):
  flutter_edge_ai_embeddings: ^2.3.2
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
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm, // the default, .task, routes to MediaPipe
).fromNetwork(
  // On web, install gemma-4-E2B-it-web.litertlm from the same repository.
  'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
).install();

// FlutterEdgeAiModelConfig.fileType does not affect routing; installModel's
// fileType does.

// 3. Create a Genkit instance with the plugin.
final ai = Genkit(plugins: [
  GenkitFlutterEdgeAiPlugin(
    models: [
      FlutterEdgeAiModelConfig(
        name: 'gemma-4-e2b',
        modelType: ModelType.gemma4,
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
  model: flutterEdgeAi.model('gemma-4-e2b'),
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
  model: flutterEdgeAi.model('gemma-4-e2b'),
  prompt: 'Write a short story.',
);

final reply = StringBuffer();
await for (final chunk in stream) {
  reply.write(chunk.text); // update your UI as the reply grows
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
`INVALID_ARGUMENT`. Since 0.9.0 it resolves the active embedder again for
every request, so it follows a model core replaced in between; since 0.9.1 a
request that finds it closed resolves it again and is retried once.

### Configuration options

Pass `FlutterEdgeAiModelOptions` to tune inference:

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-4-e2b'),
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
on this platform is `UNIMPLEMENTED`, which a `genkit_hybrid` router falls back
on. An installed model the app cannot run (no engine registered for it) is
`FAILED_PRECONDITION`, which no router hides.

</Info>

### Tool calls

Pass Genkit tools as usual; the model calls them through the engine's function
calling (a tool-capable model, see [Function calling](/docs/function-calling)):

```dart
final response = await ai.generate(
  model: flutterEdgeAi.model('gemma-4-e2b'),
  prompt: 'What is the weather in Paris?',
  tools: [weatherTool],
);
```

Tool `ref`s travel as call ids both ways (`genkit_flutter_edge_ai` 0.10.0,
which requires `flutter_edge_ai` ^2.4.0). A tool request's `ref` is the call's
`FunctionCallResponse.id`, or `call_0`, `call_1`, … when the engine gives none
(of the published engines only `flutter_edge_ai_llama` does), and never repeats within a turn. In the history
the plugin sends back, a request's `ref` becomes its call's id
(`Message.toolCall(calls:)`) and a tool response's `ref` its `toolCallId`.

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
  model: flutterEdgeAi.model('gemma-4-e2b'),
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
  model: flutterEdgeAi.model('gemma-4-e2b'),
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

Hybrid on-device/cloud routing for Genkit. A router sends each generate call to
one of its targets — a model on the device or in the cloud — once, at the first
turn of the tool loop, and keeps it there for the whole loop. Deterministic
rules decide first; a classifier, such as an on-device decider, decides the
rest.

`genkit_hybrid` depends only on `genkit` (and `schemantic`, which Genkit itself
is built on) — it has no dependency on flutter_edge_ai and works with any
Genkit models.

### Add to pubspec.yaml

```
dependencies:
  genkit_hybrid: ^0.4.0
  genkit: ^1.0.0
```

### Basic usage

```dart
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

// The on-device plugin only, and no `model:`: a call that forgets the router
// must have nowhere to go.
final ai = Genkit(plugins: [edgeAi]);

final router = defineHybridRouter(
  ai,
  targets: {
    kOnDevice: HybridTarget.onDevice(
      flutterEdgeAi.model('gemma-4-e2b'),
      warmUp: flutterEdgeAi.warmUp, // loads the model with this target's config
    ),
    kCloud: HybridTarget.cloud(googleAI.gemini('gemini-2.5-flash')),
  },
  cloudPlugins: [googleAI(apiKey: apiKey)], // given to the router only
  policies: {
    'smart': RoutePolicy(
      rules: [
        RouteRule.offline(isOnline: () => net.isOnline),
        RouteRule.inputSize(maxChars: 3000, small: kOnDevice, large: kCloud),
      ],
      classifier: myClassifier,
      labels: {
        'private': RouteDecision.only(kOnDevice), // never leaves the device
        'smalltalk': RouteDecision.prefer(kOnDevice),
        'code': RouteDecision.prefer(kCloud),
      },
      fallback: [kOnDevice],
    ),
  },
  defaultPolicy: 'smart',
);
await router.warmUp(); // at app start: the classifier and the model load now

final response = await router.generate(prompt: 'Hello!');
print(response.route); // target, model, source, label, score, routeTime
```

`router.generate` and `router.generateStream` take what `ai.generate` takes
except `model` and `config` — each target carries its own config on its
`ModelRef` — plus `policy:` and `pin:`. `router.definePrompt` defines a prompt
routed with a fixed policy.

`router.warmUp()` warms every policy's classifier and every on-device target
given a `warmUp` at once, so the first request waits for none of them; it
completes when all have ended, with the first failure if one failed.

### The cloud is reachable only through the router

The cloud plugins go to the router, which keeps them in a Genkit instance of
its own. The app's `ai` gets one proxy model per cloud target, which serves a
request only when the router chose that target for that call: a direct call to
it, or an app middleware that switches a device decision to it, fails with
`PERMISSION_DENIED`. The decision ends with its attempt, so a zone kept from it
no longer reaches the cloud, and the caller's `onChunk` runs outside it.
`defineHybridRouter` refuses a Genkit created with a default `model:`, and on
every cloud call the router checks that the app's `ai` cannot resolve the cloud
model itself. Define one router per Genkit: Genkit cannot unregister it, and its
name cannot be reused.

### Policies, rules and decisions

| `RoutePolicy` field | Meaning |
|---|---|
| `rules` | synchronous rules, in order; the first decision wins |
| `classifier` | asked only when no rule decided |
| `labels` | classifier label → `RouteDecision`; an unknown label fails the call |
| `onAbstain` | the decision for an abstain; default `RouteDecision.only(kOnDevice)` |
| `onUnavailable` | the decision while the classifier is unavailable (not ready yet, or its decider closed); default: the call fails; `route.reason` keeps why |
| `fallback` | targets a `prefer` decision may move to: after a transient failure, for a missing capability, after a rejected cascade |
| `cascade` | a check on the result; false escalates along `fallback` |

Built-in rules: `RouteRule.custom(name, fn)`, `RouteRule.offline(isOnline:)`,
`RouteRule.inputSize(maxChars:, small:, large:)` and
`RouteRule.budget(available:, premium:, cheap:)`. A decision is
`RouteDecision.prefer(target)`, which may move to another target, or
`RouteDecision.only(target)`, which never does; `pin:` on a call is `only`. Map
a label that must stay on the device to `only(kOnDevice)`.
`HybridTarget.onDevice(…, supports: {ModelCapability.vision, …})` (or `.cloud`)
declares what a target can do, and a request that needs more moves a `prefer`
decision to the first capable fallback target. `RouteClassifier` and
`RouteRule` are abstract base classes: extend them, as `final` classes.

### Fallback, cascade and consent

Fallback and cascade happen only at the first turn, for a `prefer` decision,
never on a resume, and only while nothing ran: no chunk reached the caller and
no tool ran, since re-running a tool loop would re-run its tools. A failure
moves the call to a device target when it is transient (`UNAVAILABLE`,
`DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED`, `INTERNAL`, `UNIMPLEMENTED`, or an
error without a Genkit status), and to a cloud target only on `UNAVAILABLE`,
`DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED` or `UNIMPLEMENTED`: `INTERNAL` and
errors without a status are what a device bug or an over-long input raises on
every request. `route.reason` says why the call moved. A streamed cascade
attempt holds its chunks until the verdict, or until a tool runs.

`confirmCloud: (request) => …` is asked once per call for each cloud target it
is about to use; a cancel ends the wait. False on the decided target keeps a
`prefer` call on the device, and fails a pin, an `only` decision and a router
without a `kOnDevice` target; false on a fallback target skips it.

### Decide on the device with a Decider

`genkit_flutter_edge_ai`'s `DeciderRouteClassifier.load` turns an EmbeddingGemma 2
decider into the router's classifier; its options are the labels:

```dart
final intents = DeciderRouteClassifier.load(() async {
  final embedder = await FlutterEdgeAi.getActiveEmbedder();
  return embedder.createDecider(options: intentOptions);
}); // loading starts now; router.warmUp() waits for it

// In the policy:
classifier: intents,
labels: {
  'smalltalk': RouteDecision.prefer(kOnDevice),
  'code': RouteDecision.prefer(kCloud),
},
```

`DeciderRouteClassifier.load` keeps the decider; a failed load fails the
requests waiting for it and runs again at the next one, and `reload()` refits,
closing the old decider once the new one is ready. To keep the decider
yourself, `deciderRouteClassifier(() => decider)` asks your provider per
request. A decider error fails the call, never an abstain — an input over the
embedder's limit included, so keep `RouteRule.inputSize` before the classifier.
See [Decisions](/docs/decisions).

### Errors

`router.generate`, `generateStream` and a routed prompt's `call`/`stream` throw
`HybridRoutingException` when the router refuses; a sub-agent's refusal inside
a tool fails the outer call as a tool failure instead. Other failures stay what
Genkit makes of them: a result with `finishReason: FinishReason.failed`, the
error in `error` and the original exception in `cause`; a cancel or a
`maxTurns` overrun ends with `FinishReason.aborted`. A cloud model can also
stop on its own terms: `genkit_google_genai` reports a safety block as
`FinishReason.blocked`. Treat every finish other than `stop`, `length` and
`unknown` as a failure, after handling `FinishReason.interrupted`:

```dart
final result = await router.generate(prompt: 'Hi');
final reason = result.finishReason;
if (reason == FinishReason.interrupted) {
  // Answer with router.generate(messages: result.messages, interruptRespond: ...):
  // the router resumes on the target that was interrupted.
} else if (reason != FinishReason.stop &&
    reason != FinishReason.length &&
    reason != FinishReason.unknown) {
  throw result.cause ??
      StateError(result.finishMessage ?? 'The model stopped: $reason');
}
```

<Info>

Genkit's tracing records the full prompt on every span. An exporter with
content capture on sends the text of every request off the device, the
on-device ones included: in a hybrid app keep content capture off, or redact.

</Info>

### Migrating from 0.3

`hybridModel`, `hybridModelOnDeviceCloud`, `cascadeModel` and the
`RoutingStrategy` family are deprecated in 0.4.0 and removed in 0.5.0. They
routed per model call, so inside a tool loop a fallback or a network change
could switch models between turns.

| 0.3 | 0.4 |
|---|---|
| `hybridModel` / `hybridModelOnDeviceCloud` | `defineHybridRouter` + `router.generate` |
| `PreRoutingStrategy(fn)` | `RouteRule.custom(name, fn)` |
| `ConnectivityStrategy(...)` | `RouteRule.offline(isOnline:)` |
| `InputSizeStrategy(threshold:, ...)` | `RouteRule.inputSize(maxChars:, ...)` |
| `CostStrategy(...)` | `RouteRule.budget(...)` |
| `FirstMatch([...])` | `RoutePolicy.rules` |
| `FallbackStrategy(order)` / `WithFallback` | a rule's `prefer` + `RoutePolicy.fallback` |
| `CapabilityStrategy(supports:)` | `HybridTarget.onDevice/.cloud(…, supports:)` |
| `cascadeModel(accept:)` | `RoutePolicy.cascade` |
