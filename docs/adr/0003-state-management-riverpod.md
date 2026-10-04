# ADR 0003: Riverpod 3 for state management

**Status:** accepted (TQ5, 2026-10-04) · Related: VA-0.3.1, VA-2.1.4

## Context

Flutter does not prescribe state management. The app has three kinds of state: a streaming
chat (tokens arriving over time, tool activity, a surface state machine), long-lived app
state (profile, model catalog, allowlist, disclosure acknowledgement), and plain screen
state (form fields, scroll). The owner is re-learning Flutter and wants the trade-offs
written down.

## Options

| Option | How it works | Strengths | Costs |
|---|---|---|---|
| `setState` + `InheritedWidget` | Built in. Local state in widgets; shared state passed down the tree | Zero dependencies; what every tutorial starts with | Shared state becomes boilerplate; async streams need manual lifecycle; hard to test without widgets |
| `provider` | The 2019-era standard: `ChangeNotifier` objects exposed through the tree | Simple mental model; huge install base | Depends on widget tree position; no compile-time safety on lookup; the author moved on to Riverpod |
| **Riverpod 3** | Providers are global declarations, not tree nodes; `Notifier`, `AsyncNotifier` and `StreamProvider` cover sync, async and streams; `ref.watch` rebuilds precisely | Testable without widgets (`ProviderContainer`); providers can depend on providers; streams and futures are first-class; compile-safe; optional code generation can be skipped | A new vocabulary (`ref`, `watch`/`read`/`listen`, auto-dispose); global providers need discipline about scope; v3 is recent and some articles describe v2 |
| Bloc / Cubit | Events in, states out, through a `Bloc` class; strict unidirectional flow | Very explicit; great audit trail; big enterprise following | Ceremony: event classes, state classes, transitions for every change; heavy for a one-person demo |
| `signals` / MobX | Fine-grained reactive values | Minimal rebuilds; terse | Smaller ecosystems; less idiomatic for Flutter teams; implicit dependency tracking can surprise |

## Decision

Riverpod 3 without code generation. Specifically:

- `Notifier` classes for the surface state machine, the buyer profile, the model catalog.
- `AsyncNotifier` for model loading and downloads.
- A `StreamProvider` family (or a `Notifier` that owns the stream) for the active chat turn,
  so token streaming and tool status render through `ref.watch` rather than `setState`.
- Plain widget state for form fields and scroll positions.

Code generation is skipped to keep the learning surface small; it can be added later for
the `@riverpod` annotations if the boilerplate grows.

## Consequences

- Business logic lives in notifiers that unit tests drive with a `ProviderContainer`, no
  widget tree required.
- Every screen reads state through `ref.watch`; there is no `BuildContext` plumbing for
  shared state.
- Reviewers who know Bloc will find it less ceremonial but recognize the same separation.
