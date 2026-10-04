# genkit_hybrid

Provider-agnostic hybrid routing for [Genkit](https://pub.dev/packages/genkit). Combine
existing Genkit models (on-device, cloud, anything) behind one routing policy. The result
is an ordinary `Model` — your app still calls a single `ai.generate`.

```dart
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

final ai = Genkit();

// onDeviceModel and cloudModel are ordinary Genkit Models you already have —
// e.g. from genkit_flutter_edge_ai (on-device) and genkit_google_genai (cloud).
final smart = hybridModelOnDeviceCloud(
  onDevice: onDeviceModel,
  cloud: cloudModel,
  strategy: ConnectivityStrategy(
    isOnline: () => connectivity.isOnline,
    online: kCloud,
    offline: kOnDevice,
  ),
);

// The hybrid model is an ordinary Model — register it, then use it like any other.
ai.registry.register(smart);

final res = await ai.generate(model: smart, prompt: 'Hello!');
```

## Strategies

| Strategy | What it decides on |
|---|---|
| `PreRoutingStrategy(fn)` | your own function (privacy, cost, user tier…) |
| `FallbackStrategy(order)` | fixed priority order (PREFER_ON_DEVICE / PREFER_IN_CLOUD) |
| `ConnectivityStrategy(...)` | network availability |
| `InputSizeStrategy(...)` | prompt length |
| `FirstMatch([...])` | first child strategy that decides (chain of rules) |
| `WithFallback(s, fallbackOrder: order)` | any strategy's pick + a guaranteed fallback tail |
| `CapabilityStrategy(supports: {...})` | routes to a branch that supports the request's required capabilities — vision/audio/tools/json — or `[]` when none does |
| `CostStrategy(budgetAvailable: () => ..., premium: ..., cheap: ...)` | budget-gates a premium branch against an app-supplied `bool Function()` |

### Recipe: PREFER_ON_DEVICE
```dart
hybridModelOnDeviceCloud(
  onDevice: onDeviceModel, cloud: cloudModel,
  strategy: FallbackStrategy([kOnDevice, kCloud]),
);
```

### Recipe: PREFER_IN_CLOUD
```dart
hybridModelOnDeviceCloud(
  onDevice: onDeviceModel, cloud: cloudModel,
  strategy: FallbackStrategy([kCloud, kOnDevice]),
);
```

### Recipe: route by rule, then fall back
```dart
hybridModelOnDeviceCloud(
  onDevice: onDeviceModel, cloud: cloudModel,
  strategy: WithFallback(
    FirstMatch([
      PreRoutingStrategy((c) => userOptedOutOfCloud ? kOnDevice : ''), // '' = no decision
      ConnectivityStrategy(isOnline: () => net.isOnline, online: kCloud, offline: kOnDevice),
    ]),
    fallbackOrder: [kOnDevice],
  ),
);
```

### Recipe: route by capability, try a non-capable branch anyway
`CapabilityStrategy` returns `[]` ("no decision") when no branch declares the capabilities the
request needs — wrap it in `WithFallback` to still attempt a branch rather than fail outright:
```dart
hybridModel(
  branches: {'gemma': onDeviceModel, 'gpt4o': cloudModel},
  strategy: WithFallback(
    CapabilityStrategy(
      supports: {
        'gemma': {}, // text-only
        'gpt4o': {ModelCapability.vision, ModelCapability.tools, ModelCapability.json},
      },
    ),
    fallbackOrder: ['gemma'], // best-effort: try gemma even if it can't handle the media
  ),
);
```

### Recipe: cascade — cheap first, escalate when the answer isn't good enough
`cascadeModel` runs branches in order and escalates when `accept` rejects a response (or the
branch fails transiently). Unlike `hybridModel`'s strategies, it needs the *response*, not just
the request, to decide — so it isn't a `RoutingStrategy` and is built directly as a `Model`:
```dart
final smart = cascadeModel(
  branches: {'gemma': onDeviceModel, 'gpt4o': cloudModel},
  order: ['gemma', 'gpt4o'],
  accept: (response) => response.text.length > 20, // any predicate: length, regex, JSON-parses…
);
ai.registry.register(smart);
```

## Streaming + fallback

Fallback during streaming happens **only before the first token**. If a branch fails
before emitting any token, the next branch is tried transparently. Once the first token has
streamed, a later failure propagates as an error (a partially delivered response cannot be
silently re-routed).

> **`cascadeModel` is non-streaming in v1.** A quality verdict needs the full response before
> deciding whether to escalate, so a streaming caller receives the accepted branch's response as
> ONE final chunk — no intermediate tokens, and the UI sits idle for up to one full sequential
> model run per branch in `order` while the cascade plays out underneath.

## Error policy

Fallback fires on **transient/availability** failures (network/timeout/OOM, or `GenkitException`
with `UNAVAILABLE` / `DEADLINE_EXCEEDED` / `RESOURCE_EXHAUSTED` / `INTERNAL`). **Permanent**
errors (`INVALID_ARGUMENT`, `PERMISSION_DENIED`, `UNAUTHENTICATED`, `FAILED_PRECONDITION`,
`NOT_FOUND`) propagate immediately — they would fail the same way on every branch. Note: a branch
that throws a `GenkitException` without setting `status` (it defaults to `INTERNAL`) — or any
non-`GenkitException` error — is treated as transient and retried, so a truly permanent failure
surfaced that way will be re-attempted on the next branch.

## Not in v1

- A registered Genkit plugin with a named action (the factory returns a `Model` directly).
