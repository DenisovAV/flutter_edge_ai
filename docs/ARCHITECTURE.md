# Architecture

**Status:** draft, revised 2026-10-04 after the first question round. The pure-Dart layer
described in sections 5 and 6 exists (untested until a Dart SDK is installed); the Flutter
app does not yet. Open items are tagged `Q#` / `TQ#`.

## 1. The idea in one paragraph

A buyer talks to an assistant that runs on their phone. The assistant extracts what the
buyer said into structured facts, calls deterministic tools for anything numeric, and then
decides what to show and where: a single card docked under the content, a fullscreen
breakdown, a side-by-side compare, a question with tappable answers. The screen is composed
from the conversation, not designed in advance, but only from a registry of components
that render verified numbers. The content above the conversation is a vehicle list, a
comparison, or a live web page the assistant can read from.

## 2. What the fork gives us

| Package (in `packages/`) | Role here |
|---|---|
| `flutter_edge_ai` (core) | model install, sessions, `Message`/`Tool` types, `generateChatResponseWithTools` loop, engine registry |
| `flutter_edge_ai_litertlm` | the `.litertlm` engine for Gemma 4, Qwen3, FunctionGemma on Android and iOS |
| `flutter_edge_ai_builtin_ai` | OS models (Apple Foundation Models, Gemini Nano), documented option (TQ9) |
| `flutter_edge_ai_diagnostics` | memory measurement for `docs/MEASUREMENTS.md` |
| `flutter_edge_ai_agent` | reference for a tool loop and a sandboxed webview; patterns borrowed, package not necessarily used |
| `flutter_edge_ai_speech` | push-to-talk, stretch (Q12) |
| `flutter_edge_ai_sqlite` + `_embeddings` | RAG over long pages, follow-on (TQ19) |

What it does not give us, and what the project is: the app, the finance engine, the policy
layer, the buyer profile, the component registry, the browser agent, the model catalog UX.

## 3. Layout (ADR 0005)

```
apps/motormind/                       Flutter app (pub workspace member; not created yet)
  lib/
    app/                              bootstrap, router (go_router), theme, build flavors
    features/
      advisor/                        surface state machine, chat, tool status, question chips
      content/                        content area host: vehicles | browser | compare
      vehicles/                       list, detail, compare; inventory sources
      browser/                        webview mode, page extraction, approved sites, form preview
      finance/                        breakdown screens rendered from tool results
      models/                         catalog, download (OTA manifest), switching, diagnostics
      history/                        conversation list, new conversation
      settings/                       disclosures, privacy, analytics opt-in, data wipe
      ads/                            fixed ad slot; compiled in only in the store flavor
    services/                         AdvisorModelService, storage (drift), reference APIs, analytics
  integration_test/
  packages/
    vehicle_finance/                  pure Dart: calculators, tables, assumptions   ← exists
    advisor_core/                     pure Dart: tools, handlers, guard, policy,
                                      disclosures, profile, component registry      ← exists
```

## 4. The advisor turn

```
user text ──► AdvisorSession
                 system prompt = persona + tone + policy + tool catalog
                               + component registry + profile summary
                 ▼
            on-device model ──► FunctionCallResponse(name, args)
                 │                       │
                 │                       ▼
                 │              ToolDispatcher (app)
                 │                ├─ finance tools ──► FinanceToolHandlers (advisor_core)
                 │                │                     └─► vehicle_finance ──► ToolResult(id, json)
                 │                ├─ update_profile ──► BuyerProfile.applyUpdate
                 │                ├─ find_vehicles ───► InventorySource
                 │                ├─ read_page ───────► BrowserFeature.extract
                 │                └─ present ─────────► PresentRequest.validate ──► SurfaceNotifier
                 │                       │
                 │   Message.toolResponse(result.toModelJson()) ◄──┘
                 ▼
            on-device model ──► TextResponse tokens (narration)
                 ▼
            NarrationGuard.check(narration, [tool results, user inputs])
                 │  unmatched numbers → regenerate once with a stricter instruction
                 │                     → else templated sentence + the card
            PolicyCheck.check(narration) → flags → banner (reply still shown)
                 ▼
            transcript + components rendered FROM ToolResult json
```

The SDK's `generateChatResponseWithTools(onToolCall:)` drives the call → result →
continue loop, so the app supplies `onToolCall` and consumes text. Everything inside
`onToolCall` is deterministic and unit-tested in `advisor_core`.

### Model roles (TQ7, TQ8)

"Extractor" and "narrator" are two roles that one model fills by default. The session
interface keeps them separate so a two-model mode (FunctionGemma extracts, Gemma 4
narrates) is a settings change.

## 5. Finance engine (`vehicle_finance`, exists)

Pure functions returning `CalcResult`s that carry `inputs` and `assumptions`:
`monthlyPayment`, `maxPrincipal`, `amortizationSchedule`, `summarizeLoan`, `tradeEquity`,
`estimateDeal` (consumer layout: cash at signing, amount financed, payment, total cost),
`estimateLease`, `creditBandForScore`, `AprTable` (JSON-loadable, dated, labeled
illustrative), `assessAffordability` (warnings only), `estimateOwnership` (rough tables,
labeled), `whatIfVariants`. See the package README. A TILA-style view is a presentation
toggle over the same `DealEstimate` (Q19, stretch).

## 6. Advisor core (`advisor_core`, exists)

- `AdvisorTools.all`: the ten tool specifications with JSON schemas; descriptions say *when*
  to call.
- `FinanceToolHandlers`: arguments → `vehicle_finance` → `ToolResult` with an id the model
  can reference in `present`. Bad arguments return an error the model can correct.
- `NarrationGuard`: numbers in the reply must appear in tool results or user inputs,
  tolerant of formatting, whole-dollar rounding and 2% spoken rounding; years and small
  counts pass.
- `PolicyCheck`: urgency, guarantee, pressure, advice and compensation patterns → flags for
  a banner (TQ15: flag, do not block).
- `Disclosures`: versioned registry; `gateVersion` changes when any wording changes.
- `BuyerProfile`: user-labeled needs and wants (`need` / `want` / `unlabeled`), constraints,
  tone; `applyUpdate` from the `update_profile` tool; `toPromptSummary` for the system prompt.
- `ComponentRegistry` and `PresentRequest`: the generative-UI vocabulary and its validator
  (ADR 0006).

## 7. The advisor surface (VA-2.1, Q8)

Three states, one widget tree, a toggle control the user owns:

```
 collapsed (bubble)  ◄──────────────────────────────────────────┐
     │ tap bubble / new reply                                   │ "back" / collapse
     ▼                                                          │
 docked (bottom sheet, 30–60%)  ──── present(fullscreen) ────►  fullscreen (breakdowns)
     ▲      drag up past threshold                              │
     └──────────────────────── drag down / back ────────────────┘
```

- A persistent **expand/contract control** (the "</>"-style toggle, Q8) cycles the surface
  and can **pin** it; while pinned, `present` requests update content but not the surface.
- The content area owns the space above the sheet and resizes with it; a web page in it can
  be zoomed independently.
- Keyboard insets are handled at the scaffold so the input never hides.

## 8. Tone and conversation (Q9, Q16, Q17)

- First turn offers `question_chips`: "Practical, stretch, or just for fun?" The answer sets
  `BuyerProfile.tone`; the persona prompt adapts (sympathetic and concrete for practical,
  supportive but realistic for stretch, playful for fun, precise for budgeting). Tone can be
  changed any time and the advisor mirrors the user's register.
- Needs versus wants: the advisor records items as `unlabeled` unless the user framed them;
  it may ask "need or nice-to-have?" and the user can ignore the question.
- Conversations are persisted (drift). A history list and a "new conversation" action
  behave like other AI apps. The structured profile is shared across conversations;
  transcripts are per conversation.

## 9. Content area and vehicle discovery (Q7, Q10, Q11, Q15)

- Modes: **vehicles** (list, detail, compare rendered from `find_vehicles`), **browser**
  (`flutter_inappwebview`, works on iOS and Android), **compare**.
- `InventorySource`: `BundledInventory` (sample JSON, labeled) first. Live listings come
  from the browser: a **curated site list** the project tests, each with an extraction
  recipe; unknown sites fall back to generic text extraction.
- **Browser-assisted data entry** is the core pattern: the user finds a trade-in value,
  insurance quote or listing on a site they trust; the assistant reads the page and offers
  the figures as *inputs* to the finance tools, labeled with the source URL. The app does
  not try to own valuation or total-cost data.
- Reference APIs (NHTSA vPIC, FuelEconomy.gov) fill specs and efficiency, cached locally.

## 10. Browser agent (VA-6, Q20, Q23, TQ18, TQ19, TQ36)

- Navigation policy: `http(s)` only, downloads and external schemes blocked, JavaScript on.
- `read_page`: inject a Readability-style extraction, strip navigation, ads and headers at
  the DOM level before text extraction, cap to a token budget, return cleaned text plus
  pattern-found price, mileage, year. Long pages: RAG follow-on.
- Presentation of third-party pages in a half screen is a known problem (Q23): options are
  auto-scroll to main content, a reader-mode rendering of the extracted content, or
  fullscreen browser with the advisor collapsed. To be prototyped early.
- Form filling: approved-sites allowlist, per-action preview, explicit confirm, never
  auto-submit, a hard exclusion list (SSN, account and card numbers), and the browser
  disclosure shown at first use.

## 11. Models and delivery (TQ7, TQ10, TQ11)

`docs/MODELS.md` covers candidates. The catalog is an OTA manifest (id, size, checksum,
URL, minimum RAM, capabilities); sources are Hugging Face (token entered in-app) or a
self-hosted mirror. An in-app diagnostics screen measures and exports JSON, with an
optional upload if a collection endpoint exists.

## 12. Build flavors: demo and store (Q22)

Advertising is a **build-time** decision. The `demo` flavor compiles no ad SDK and shows no
slot; the `store` flavor includes a fixed, labeled ad slot in the same place on every screen.
Implemented as a `--dart-define=MOTORMIND_ADS=true` flag plus platform flavors so the ad SDK
is absent from demo binaries. Ads never appear inside the chat or inside a result component,
and never affect ranking.

## 13. Privacy, storage, analytics (Q21, TQ21, TQ22)

- drift (SQLite) for profile, conversations, allowlist, reference cache; secure storage for
  the Hugging Face token; shared preferences for small flags.
- Analytics: anonymous event counts (screen views, tool names called, model id, surface
  transitions), no free text, no financial values, opt-in, disclosed in the gate and the
  terms. Provider to be chosen (Q33).
- A debug network audit logs every outbound host; a test fails on an unexpected host.

## 14. Risks and unknowns

- Extraction quality on small models; mitigated by the golden dataset and clarifying
  questions.
- Third-party page presentation in half a screen; prototype early.
- Memory with a 2.4 GB model beside a webview; measure on the Fold 4 and iPhone 15 Pro.
- No toolchain on the development Mac yet; `docs/SETUP.md` is the fix.
- Scraping terms of service on listing sites; user-driven reading in a webview is ordinary
  browsing, automated extraction at scale is not (Q31).
