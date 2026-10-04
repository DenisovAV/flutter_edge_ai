# ADR 0004: go_router for navigation

**Status:** accepted (TQ6, 2026-10-04) · Related: VA-0.3.1, VA-4.1.1

## Context

The app has few top-level routes (disclosure gate, home with the advisor surface,
breakdown screens, model manager, settings, conversation history) but two behaviors that
make routing non-trivial: a **gate** that must be satisfied before anything else shows, and
a later wish to deep-link into a specific breakdown or shared estimate.

## Options

| Option | What it is | Strengths | Costs |
|---|---|---|---|
| `Navigator` 1.0 (`push`/`pop`) | Imperative stack built into Flutter | Simplest; fine for a few screens | No URL model; redirects and guards are hand-rolled; deep links need extra work |
| `Navigator` 2.0 (Router API) | Declarative router built into Flutter | Full control; no dependency | Verbose; the Flutter team itself recommends a package on top of it |
| **go_router** | The Flutter team's package on top of Navigator 2.0; URL-based routes, redirects, nested shells | Maintained by the Flutter team; `redirect` is exactly the disclosure gate; deep links for free; shell routes keep the advisor surface persistent across content routes | Another API to learn; some patterns (dialogs, bottom sheets) still use Navigator 1.0 calls |
| auto_route | Code-generated, strongly typed routes | Type-safe arguments; nested navigation | Build-runner step; heavier; smaller community |
| beamer | Location-based declarative router | Flexible | Smaller community; less documentation |

## Decision

`go_router`, with:

- A top-level `redirect` that sends any route to `/disclosures` until the current
  `Disclosures.gateVersion` has been acknowledged.
- A `ShellRoute` for the main experience so the advisor surface (bubble, docked panel) stays
  mounted while the content area navigates between vehicles, browser and compare routes.
- Fullscreen breakdowns as pushed routes under the shell, so "back to vehicles" is the
  system back gesture.

## Consequences

- The disclosure gate is one function, testable in isolation.
- Future deep links (`motormind://estimate/<id>`) map to existing routes.
- Bottom sheets and dialogs still use the imperative API; that is normal with go_router.
