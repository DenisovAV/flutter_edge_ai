# genkit_hybrid

Hybrid on-device/cloud routing for [Genkit](https://pub.dev/packages/genkit). A router sends
each generate call to one of its targets — a model on the device or in the cloud — once, at the
first turn of the tool loop, and keeps it there for the whole loop. Deterministic rules decide
first (offline, too long, out of budget, must stay private); a classifier decides the rest.

Pure Dart: it depends on `genkit` (and `schemantic`, which Genkit itself is built on) only, so it
works with any on-device or cloud plugin.

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
- **The decision ends with its attempt.** A zone kept from it (a stored `Zone`, a timer) no
  longer reaches the cloud, and the caller's `onChunk` runs outside it.
- **One router per call.** A second router ref in the same chain is refused; a tool runs outside
  the decision, so a sub-agent tool that calls the router is routed on its own.
- **One router per Genkit.** Genkit cannot unregister a middleware or a model, and a router's
  name cannot be reused; to change targets, build a new Genkit and define the router on it.

## Policies

A router holds named policies; a call picks one with `policy:`, or gets `defaultPolicy`.

| Field | Meaning |
|---|---|
| `rules` | synchronous `RouteRule`s, in order; the first decision wins |
| `classifier` | a `RouteClassifier`, asked only when no rule decided |
| `labels` | classifier label → `RouteDecision`; an unknown label fails the call |
| `onAbstain` | the `RouteDecision` for an abstain; default `RouteDecision.only(kOnDevice)` |
| `onUnavailable` | the `RouteDecision` while the classifier is unavailable (not ready yet, or its decider closed); default: the call fails; `route.reason` keeps why |
| `fallback` | targets a `prefer` decision may move to: after a transient failure, for a missing capability, after a rejected cascade |
| `cascade` | `(GenerateResult) => bool`: false escalates along `fallback` |

A decision is `RouteDecision.prefer(target)` (may move: fallback, cascade, capability) or
`RouteDecision.only(target)` (never moves; the call fails instead). Map a label that must stay on
the device to `only(kOnDevice)`. `pin:` on a call is `only` and skips rules and classifier.
`RouteClassifier` and `RouteRule` are abstract base classes: extend them, as `final` classes.

Built-in rules: `RouteRule.custom(name, fn)`, `RouteRule.offline(isOnline:)` (offline → `only`
on-device), `RouteRule.inputSize(maxChars:, small:, large:)`,
`RouteRule.budget(available:, premium:, cheap:)`.

`HybridTarget.onDevice(…, supports: {ModelCapability.vision, …})` (or `.cloud`) declares what a
target can do; a request that needs more moves a `prefer` decision to the first capable
`fallback` target. `kOnDevice` must hold an on-device target.

## Fallback and cascade

Both happen only at the first turn, only for a `prefer` decision, never on a resume, and only
while **nothing ran**: no chunk reached the caller and no tool ran. Re-running a tool loop would
re-run its tools. A failure moves the call to a device target when it is transient
(`UNAVAILABLE`, `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED`, `INTERNAL`, `UNIMPLEMENTED`, or an error
without a Genkit status, such as a network error), and to a cloud target only on `UNAVAILABLE`,
`DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED` or `UNIMPLEMENTED`: `INTERNAL` and errors without a
status are what a device bug or an over-long input raises on every request. `route.reason` says
why the call moved (`fallback: onDevice failed with UNAVAILABLE: <message>`, `cascade: onDevice
rejected`) and, when no later target ran, what was skipped (`…; cloud refused by confirmCloud`).

A streamed cascade attempt holds its chunks until the verdict: accepted, they are sent; rejected,
they are dropped and the next target streams live. A tool that runs releases them, since the
cascade no longer applies.

## Consent

`confirmCloud: (request) => …` is asked once per call for each cloud target it is about to use, a
resume included; a cancel of the call ends the wait. False on the decided target keeps a `prefer`
call on the `kOnDevice` target (`source: consentRefused`), and fails a pin, an `only` decision and
a router without that target; false on a fallback target skips it.

## Prompts and resume

`router.definePrompt(...)` returns a `HybridPrompt` routed with a policy and pin fixed at
definition; its `call`/`stream` throw like `router.generate`. Its registered `prompt` (and a
`.prompt` file with `use: [{name: hybrid-router}]`) returns Genkit's result instead.

An interrupted call is stamped with the router's decision on the interrupted message, so a resume
(`router.generate(messages:, interruptRespond:)`) goes back to the same target, also after an app
restart. A message without the stamp, or with another router's, resumes on the `kOnDevice`
target, and fails without one.

## Errors

`router.generate`, `generateStream` and `HybridPrompt` throw `HybridRoutingException` when the
router refuses (the decision so far is on its `route`). Other failures stay what Genkit makes of
them: a result with `finishReason: FinishReason.failed` and the exception on `cause`. Treat every
finish other than `stop`, `length` and `unknown` as a failure. A refusal belongs to the call it was
made in: a sub-agent's refusal inside a tool fails the outer call as a tool failure, not as the
outer router's refusal.

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
| `CapabilityStrategy(supports:)` | `HybridTarget.onDevice/.cloud(…, supports:)` |
| `cascadeModel(accept:)` | `RoutePolicy.cascade` |
