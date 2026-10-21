# genkit_hybrid

Hybrid on-device/cloud routing for [Genkit](https://pub.dev/packages/genkit). A router sends
each generate call to one of its targets — a model on the device or in the cloud — once, at the
first turn of the tool loop, and keeps it there for the whole loop. Deterministic rules decide
first (offline, too long, out of budget, must stay private); a classifier decides the rest.

Pure Dart: it depends on `genkit` only, so it works with any on-device or cloud plugin.

```yaml
dependencies:
  genkit: ^1.0.0
  genkit_hybrid: ^0.4.0
```

```dart
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

// No `model:` here: a call that forgets the router must have nowhere to go.
final ai = Genkit(plugins: [edgeAiPlugin]); // the on-device plugin only

final router = defineHybridRouter(
  ai,
  targets: {
    kOnDevice: HybridTarget.onDevice(flutterEdgeAi.model('gemma-4-e2b')),
    kCloud: HybridTarget.cloud(googleAI.gemini('gemini-2.5-flash')),
  },
  // The cloud plugin goes to the router only, never to `ai`.
  cloudPlugins: [googleAI(apiKey: apiKey)],
  policies: {
    'smart': RoutePolicy(
      rules: [
        RouteRule.offline(isOnline: () => net.isOnline),
        RouteRule.inputSize(maxChars: 3000, small: kOnDevice, large: kCloud),
      ],
      classifier: myClassifier, // e.g. deciderRouteClassifier from genkit_flutter_edge_ai
      labels: {'smalltalk': kOnDevice, 'code': kCloud},
      fallback: [kOnDevice],
    ),
  },
  defaultPolicy: 'smart',
);

final result = await router.generate(prompt: 'Hello!');
print(result.text);
print(result.route); // target, model, source (rule/classifier/…), label, score, routeTime
```

## The cloud is reachable only through the router

- **The cloud plugins live inside the router**, in a Genkit instance of its own. The app's `ai`
  gets a proxy model per cloud target (`<router>/<target>`), which serves a request only when the
  router chose that target for that call. A direct call to the proxy, or an app middleware that
  switches a device decision to it, fails with `PERMISSION_DENIED`.
- **No default model.** `defineHybridRouter` refuses a Genkit created with `model:`: a call that
  forgets the router would go there. Without one, such a call names no model and Genkit fails it.
- **The router checks on every cloud call** that the app's `ai` cannot resolve the cloud model
  itself (its plugin given to `ai` too), and fails closed when it can.
- **One router per call.** A second router ref in the same chain is refused; a tool runs outside
  the decision, so a sub-agent tool that calls the router is routed on its own.

## Policies

A router holds named policies; a call picks one with `policy:`, or gets `defaultPolicy`.

| Field | Meaning |
|---|---|
| `rules` | synchronous `RouteRule`s, in order; the first decision wins |
| `classifier` | a `RouteClassifier`, asked only when no rule decided |
| `labels` | classifier label → target key; an unknown label fails the call |
| `onAbstain` | where an abstain goes; default `kOnDevice` |
| `onUnavailable` | where a call goes while the classifier is not ready; default: the call fails |
| `fallback` | targets tried after a transient first-turn failure, a missing capability, a rejected cascade |
| `cascade` | `(GenerateResult) => bool`: false escalates along `fallback` |

A decision is `RouteDecision.prefer(target)` (may move: fallback, cascade, capability) or
`RouteDecision.only(target)` (never moves; the call fails instead). `pin:` on a call is `only`
and skips rules and classifier.

Built-in rules: `RouteRule.custom(name, fn)`, `RouteRule.offline(isOnline:)` (offline → `only`
on-device), `RouteRule.inputSize(maxChars:, small:, large:)`,
`RouteRule.budget(available:, premium:, cheap:)`.

`HybridTarget(…, supports: {ModelCapability.vision, …})` declares what a target can do; a
request that needs more moves a `prefer` decision to the first capable `fallback` target.

## Fallback and cascade

Both happen only at the first turn, only for a `prefer` decision, never on a resume, and only
while **nothing ran**: no chunk reached the caller and no tool ran. Re-running a tool loop would
re-run its tools. A fallback needs a transient error (`UNAVAILABLE`, `DEADLINE_EXCEEDED`,
`RESOURCE_EXHAUSTED`, `INTERNAL`, `UNIMPLEMENTED`, or a non-Genkit error). A streamed cascade
attempt holds its chunks until the verdict: accepted, they are sent; rejected, they are dropped
and the next target streams live.

## Consent

`confirmCloud: (request) => …` is asked once per call that is about to go to the cloud, a resume
included. False keeps the call on the `kOnDevice` target (`source: consentRefused`), or fails it
when there is none.

## Prompts and resume

`router.definePrompt(...)` returns a `HybridPrompt` routed with a policy and pin fixed at
definition; its `call`/`stream` throw like `router.generate`. Its registered `prompt` (and a
`.prompt` file with `use: [{name: hybrid-router}]`) returns Genkit's result instead.

An interrupted call is stamped with the router's decision on the interrupted message, so a resume
(`router.generate(messages:, interruptRespond:)`) goes back to the same target, also after an app
restart. A message without the stamp resumes on the device.

## Errors

`router.generate`, `generateStream` and `HybridPrompt` throw `HybridRoutingException` when the
router refuses (the decision so far is on its `route`). Other failures stay what Genkit makes of
them: a result with `finishReason: FinishReason.failed` and the exception on `cause`. Treat every
finish other than `stop`, `length` and `unknown` as a failure.

## Telemetry can ship on-device prompts off the device

Genkit's built-in tracing records the full prompt on every span, and exports it only to the Dev
UI in development. An exporter with content capture on (genkit_otel's `contentCapturingMode`,
`captureActionIO`) sends the text of every request, the on-device ones included. In a hybrid app
keep content capture off, or redact it, or "processed on the device" stops being true.

## Migrating from 0.3

The 0.3 composite-model API still works in 0.4.0, deprecated, and is removed in 0.5.0. It routed
per model call, so inside a tool loop a fallback or a network change could switch models between
turns.

| 0.3 | 0.4 |
|---|---|
| `hybridModel` / `hybridModelOnDeviceCloud` | `defineHybridRouter` + `router.generate` |
| `PreRoutingStrategy(fn)` | `RouteRule.custom(name, fn)` |
| `ConnectivityStrategy(...)` | `RouteRule.offline(isOnline:)` |
| `InputSizeStrategy(threshold:, ...)` | `RouteRule.inputSize(maxChars:, ...)` |
| `CostStrategy(...)` | `RouteRule.budget(...)` (+ `cheap` in `fallback`) |
| `FirstMatch([...])` | `RoutePolicy.rules` |
| `FallbackStrategy(order)` / `WithFallback` | a rule's `prefer` + `RoutePolicy.fallback` |
| `CapabilityStrategy(supports:)` | `HybridTarget(…, supports:)` |
| `cascadeModel(accept:)` | `RoutePolicy.cascade` |
