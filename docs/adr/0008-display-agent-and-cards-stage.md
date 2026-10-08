# ADR 0008 — The Cards stage as the primary surface, and a display agent beside the conversation

**Status:** accepted, 2026-10-08
**Relates to:** ADR 0006 (dynamic design), ADR 0007 (reading recipes), design notes
DD-R24–R34 and Section 6

## Context

Two things were learned on a device in the first week (see the experiment log in the
design notes):

1. The in-app web page is "eye candy before selections are made." Once a search has
   found something, the person wants the list: compact, attributed, tappable. The owner's
   words: "if the user wanted to browse the website, they would not use our app."
2. Every "should this collapse?" question was a design-time decision in disguise. The
   owner asked for the components to be named and for visibility to be decided at runtime
   from screen state, by rules first and by a model as the rules prove out, and for the
   two jobs (talking with the person, arranging the screen) to be separate agents.

## Decision

### The Cards stage is primary

- A search that finds anything brings Cards forward; the web page stays one tap away and
  comes back by itself when it has to be seen (a human check, a page the person opened).
- Listing tiles are compact: thumbnail, title, price and mileage, **the source site and
  the read age on every tile**, so a mixed-site stage reads like a search engine's results
  and never pretends to be one inventory.
- A tap expands the tile in place (open on the site, monthly cost, not this one) and
  marks it **viewed**; a heart marks it **liked**; "not this one" **dismisses**. These are
  signals the app keeps (`ListingSignals`) and may later summarize for the model in words
  (makes, counts), never as numbers it could restate.
- A soft edge at the bottom of a scrollable stage says there is more below; whether to
  nudge is a display decision, not a constant.

### A display agent, rules first

- `DisplayDecision` is a small record: filters card mode, whether transcript notes show,
  which stage (web or cards), the stage's share of the screen when docked, and an optional
  one-line cue. Nothing else about the screen is the agent's.
- `ScreenState` is its input: surface state, keyboard, whether filters are set and what
  they say, card and listing counts, the stage mode and whether the person set it, the
  person's last manual expand, the last thing the person typed (so "show me the website"
  works without a tool), and whether the conversation is busy. The agent never sees the
  conversation.
- `RulesDisplayAgent` is the decision table from the design notes, logged on every
  change. `ModelDisplayAgent` opens a **second session of the loaded model** with a tiny
  system prompt and a one-line state, asks for one JSON object, parses it leniently, and
  falls back to the rules on anything it cannot read. It runs only while the conversation
  is idle, after a short debounce, and a newer screen change cancels a stale answer.
- The person's manual choices are inputs and they win until the context changes
  (DD-R13): a flipped stage holds until the next search; an expanded filters card holds
  until a filter changes.
- A small fixed indicator in the panel header shows when the display agent is working and
  who made the current decision. It never takes a row.
- The model agent is **off by default** (a switch on the Models screen) until its cost is
  measured on a phone.

## Consequences

- On the LiteRT-LM FFI engine, sessions multiplex one native conversation: a switch
  replays the other session's history. A display decision therefore costs its own small
  prefill plus a replay of the conversation on the next user turn. That is exactly the
  number the project wants to measure (TQ59: "prompt size per turn"); it is logged with
  every decision.
- Two sessions of Gemma 4 E2B hold two contexts; on a 6 GB phone that is a memory risk.
  The display session is opened per decision and closed after.
- The rules table and the model produce the same decision shape, so the fake-model
  harness can score one against the other row by row (DD-R21, R23).

## Alternatives considered

| Option | Why not |
|---|---|
| Ask the interaction agent to also arrange the screen | Tokens on every turn and a worse job at both; the owner asked for two agents. |
| A second, smaller model for display | The engine loads one model at a time; a second file is another download and more memory. Two sessions of one model measure the same thing more cheaply. |
| Keep the rules only | Fine for the demo's reliability, but it does not test the thesis. Rules stay as the fallback and the benchmark. |
| Web page as the primary stage | The page is the source, not the product; half a phone screen of a listing site is unusable. |
