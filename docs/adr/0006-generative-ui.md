# ADR 0006: The model composes the screen from a component registry

**Status:** proposed · **Date:** 2026-10-04 · Related: VA-11, VA-2.1.4, Q27, Q28, TQ28

## Context

The owner's central interest is UI that is assembled at runtime from the conversation
rather than pre-designed screens. The vehicle use case is one instance; the pattern is the
point. The thesis (2026-10-04): a chat transcript is the wrong container for an assistant
that lives inside the device. A person on the other end of a chat cannot draw a list of
options, render a chart, put a web page beside a number or add a button; the on-device
model can, because the app is its hands. So the assistant should **prefer structured
interaction** (choices, forms) over prose when the answer is one of a few options or a
number, which is also cheaper in tokens and faster on a phone, and the person must always
have an **escape** (a "something else, let me type" option on every structured prompt and a
global expand/collapse toggle), the way an automated phone tree has "let me talk to a
human."

A small on-device model must not be allowed to put an invented number on screen, so the
numeric guard applies to everything it renders. Whether a small model can also lay out
well, given a good component library and clear constraints, is an open question the
project will test rather than assume; the owner's view is that today's failures come from
asking the model to treat the screen as a blank canvas, not from the approach.

## Options

| Option | What the model emits | Strengths | Costs |
|---|---|---|---|
| Fixed screens, model fills text | Nothing structural | Predictable; what most apps do | Not the idea; the UI cannot respond to the shape of the conversation |
| **Registry-driven presentation** | A `present` call naming a registered component, the tool result to render, and a surface | Safe by construction (unknown component = error); every component renders from structured data; the model decides *what* and *where* | Vocabulary limited to what is registered; adding a component is code |
| Constrained layout | A small tree (`stack`, `row`, `compare`) whose leaves are registry components, with size and priority hints | Arrangements nobody pre-drew; leaves still render verified data | More for the model to get right; needs a layout allocator in the app |
| Free layout JSON | A tree of layout nodes (column, row, card, text, number) with values | Maximum flexibility | Values in `text` nodes bypass the guard unless every leaf is data-by-reference; token cost per turn; unproven on 2B models (to be tested, not assumed) |
| Code generation | Dart or a DSL compiled at runtime | Unlimited | Not possible in release Flutter builds; unsafe |

## Decision

Climb the ladder: registry-driven presentation now, constrained layout next, free layout
as an experiment with the same leaf rule. Specifically:

1. `ComponentRegistry` in `advisor_core` is the vocabulary. Each component declares which
   tool results it can render and its default surface.
2. The model composes the screen through `present(component, result_id, surface, title)`.
   Validation rejects unknown components, mismatched results and the collapsed surface.
3. Components render only from the referenced tool result. Model text goes into the chat
   transcript, never into a component's numeric fields.
4. The surface state machine honors `present` as a *request*; the user can override and
   pin.
5. **Interaction components** (`choice`, `multi_choice`, `input_form`) let the model ask
   with tappable options or a short typed form instead of prose. Each renders an implicit
   "something else" escape that opens free text.
6. The next rung adds a constrained layout (`stack`, `row`, `compare`) whose leaves are
   still registry components, plus **layout allocation** in the app: screen space is shared
   among content, advisor surface and keyboard (about 40% of the screen when up) from the
   model's priority hints and the kind of thing being shown, so the chat area is never a
   fixed size.

## Consequences

- "Dynamic UI" is demonstrable and safe: the same conversation can produce a single card, a
  fullscreen breakdown, or a side-by-side compare depending on what the user asked.
- Each new component is a Flutter widget plus a registry entry plus a line in the prompt.
- The model's choices are logged (component, surface, timing), which becomes a measurement
  of how well a given model uses the registry, another input to the model picker.
