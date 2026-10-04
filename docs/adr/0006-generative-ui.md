# ADR 0006: The model composes the screen from a component registry

**Status:** proposed · **Date:** 2026-10-04 · Related: VA-11, VA-2.1.4, Q27, Q28, TQ28

## Context

The owner's central interest is UI that is assembled at runtime from the conversation
rather than pre-designed screens. The vehicle use case is one instance; the pattern is the
point. At the same time, a small on-device model must not be allowed to render arbitrary
UI, both for safety (it could show an invented number) and for quality (layout judgment is
not what a 2B model is good at).

## Options

| Option | What the model emits | Strengths | Costs |
|---|---|---|---|
| Fixed screens, model fills text | Nothing structural | Predictable; what most apps do | Not the idea; the UI cannot respond to the shape of the conversation |
| **Registry-driven presentation** | A `present` call naming a registered component, the tool result to render, and a surface | Safe by construction (unknown component = error); every component renders from structured data; the model decides *what* and *where* | Vocabulary limited to what is registered; adding a component is code |
| Layout JSON | A tree of layout nodes (column, row, card, text, number) with values | Maximum flexibility; the model can invent new arrangements | The model can put numbers in `text` nodes, bypassing the guard; layout quality varies; large token cost per turn |
| Code generation | Dart or a DSL compiled at runtime | Unlimited | Not possible in release Flutter builds; unsafe |

## Decision

Registry-driven presentation now, with the door open to a constrained layout JSON later:

1. `ComponentRegistry` in `advisor_core` is the vocabulary. Each component declares which
   tool results it can render and its default surface.
2. The model composes the screen through `present(component, result_id, surface, title)`.
   Validation rejects unknown components, mismatched results and the collapsed surface.
3. Components render only from the referenced tool result. Model text goes into the chat
   transcript, never into a component's numeric fields.
4. The surface state machine honors `present` as a *request*; the user can override and
   pin.
5. A later story may add a constrained layout JSON (`stack`, `row`, `compare`) whose leaves
   are still registry components, so flexibility grows without opening the numeric guard.

## Consequences

- "Dynamic UI" is demonstrable and safe: the same conversation can produce a single card, a
  fullscreen breakdown, or a side-by-side compare depending on what the user asked.
- Each new component is a Flutter widget plus a registry entry plus a line in the prompt.
- The model's choices are logged (component, surface, timing), which becomes a measurement
  of how well a given model uses the registry, another input to the model picker.
