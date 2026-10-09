# Changelog

## 0.3.0

- **Breaking:** require `genkit` ^1.0.0; each branch runs in its own trace span and honours cancellation.

## 0.2.2

- Update package documentation for the Flutter Edge AI rename.

## 0.2.1

- Widen the `genkit` constraint to `>=0.15.1 <0.17.0` so it works on both genkit 0.15 and 0.16 (no code change — uses only Model/generate/ModelRequest).

## 0.2.0

- Add `CapabilityStrategy`: route by request-required capabilities (vision/audio/tools/json).
- Add `CostStrategy`: budget-gate a premium branch against an app-supplied signal.
- Add `cascadeModel`: escalate to a premium branch when an `accept` predicate rejects the cheap response (non-streaming v1).

## 0.1.1

- Bump `genkit` to `^0.15.1` (from `^0.14.1`). No API or behavioral changes; 32 tests green.

## 0.1.0

Initial release.

- `hybridModel(branches, strategy)` — combine N named Genkit `Model` actions behind one routing policy; returns an ordinary `Model`.
- `hybridModelOnDeviceCloud(onDevice, cloud, strategy)` — binary façade with `kOnDevice` / `kCloud` keys.
- `RoutingStrategy` interface returning an ordered list of branch keys (single = pre-routing, multi = fallback, empty = no decision).
- Built-in strategies: `PreRoutingStrategy`, `FallbackStrategy`, `ConnectivityStrategy`, `InputSizeStrategy`, and combinators `FirstMatch`, `WithFallback`.
- Streaming fallback only before the first emitted token.
- Transient-vs-permanent error policy: fallback on availability errors, immediate propagation of permanent ones.
