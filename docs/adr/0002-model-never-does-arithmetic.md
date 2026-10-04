# ADR 0002: The language model never produces a financial number

**Status:** proposed · **Date:** 2026-10-04 · Related: VA-3, VA-4.2, TQ14

## Context

Small on-device models are confidently wrong at arithmetic. In a tool that shows payments,
APRs and equity positions, a wrong number is a trust and compliance failure, not a bug.
Deloitte's risk framing for the vehicle-buying assistant use case names transparency,
reliability and accountability as the risks to manage.

## Decision

The model has exactly two numeric roles: **extract** structured inputs from the user's
words (via tool calls with JSON schemas) and **narrate** results that deterministic Dart
code produced. It never computes. Specifically:

1. All calculations live in the pure-Dart `vehicle_finance` package with unit tests.
2. UI cards render numbers only from structured tool results, never from model text.
3. A narration guard checks every number in the model's reply against the turn's tool
   results and user inputs; unmatched numbers cause a regeneration, then a templated
   fallback.
4. Every result carries its inputs and assumptions, which the UI shows.

## Consequences

- More tool definitions and a stricter prompt; slightly slower turns.
- Model switching becomes safe: a weaker model degrades narration, not correctness.
- Reviewers can verify any displayed figure with a calculator.
