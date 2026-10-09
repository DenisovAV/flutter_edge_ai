# Architecture

**Status:** revised 2026-10-09. The pure-Dart layer (sections 5 and 6) and the Flutter app
exist with passing tests: the conversation and its cards, the stage, the live search and
filters card, the web pane with reading recipes and captures, the model catalog, and the
display decision table with an optional second model session (ADR 0008). Sections marked
*plan* describe direction, not code. Open items are tagged `Q#` / `TQ#`.

## 1. The idea in one paragraph

A buyer talks to an assistant that runs on their phone. The assistant extracts what the
buyer said into structured facts, calls deterministic tools for anything numeric, and then
decides what to show and where: a single card docked under the content, a fullscreen
breakdown, a side-by-side compare, a question with tappable answers. The screen is composed
from the conversation, not designed in advance, but only from a registry of components
that render verified numbers. The content above the conversation is a vehicle list, a
comparison, or a live web page the assistant can read from.

## 2. What the fork provides

| Package (in `packages/`) | Role here |
|---|---|
| `flutter_edge_ai` (core) | model install, sessions, `Message`/`Tool` types, `generateChatResponseWithTools` loop, engine registry |
| `flutter_edge_ai_litertlm` | the `.litertlm` engine for Gemma 4, Qwen3, FunctionGemma on Android and iOS |
| `flutter_edge_ai_builtin_ai` | OS models (Apple Foundation Models, Gemini Nano), documented option (TQ9) |
| `flutter_edge_ai_diagnostics` | memory snapshot that sizes the context window at load |
| `flutter_edge_ai_agent` | reference for a tool loop and a sandboxed webview; patterns borrowed, package not necessarily used |
| `flutter_edge_ai_speech` | push-to-talk, stretch (Q12) |
| `flutter_edge_ai_sqlite` + `_embeddings` | RAG over long pages, follow-on (TQ19) |

What it does not provide, and what the project is: the app, the finance engine, the policy
layer, the buyer profile, the component registry, the browser agent, the model catalog UX.

## 3. Layout (ADR 0005)

```
apps/motormind/                       Flutter app (pub workspace member)
  lib/
    app/                              bootstrap, router (go_router), theme, prefs seam, shared widgets
    features/
      advisor/                        surface state machine, stage, display rules and agent
      chat/                           the turn (ChatService), state, starters, external tools, cards/
      search/                         live search service and the filters card
      listings/                       listing tiles and the viewed/liked/dismissed signals
      browser/                        the web pane and BrowserService (reading, recipes, bot checks)
      recipes/                        reading recipes: shipped assets plus on-device overrides
      captures/                       Capture control and the Captures screen
      models/                         catalog and the Models screen
      disclosures/                    gate and long-form disclosures
      home/                           the one screen that hosts the stage and the surface
    services/                         AdvisorModelService, token store, analytics, log
  packages/
    vehicle_finance/                  pure Dart: calculators, tables, assumptions
    advisor_core/                     pure Dart: tools, pipeline, guards, policy, profile,
                                      prompt, component registry, vehicles (search, recipes)
```

Planned, not built: conversation history, settings beyond disclosures, the ads slot, drift
storage, reference APIs, integration tests on a device.

## 4. The Motormind turn

*Naming:* the person-facing name is **Motormind**; the interface never says "advisor" or
"advice" (the product is informational). `advisor` survives in package and type names only.

```
user text ──► EdgeAiChatDriver (ChatDriver)
                 system prompt = persona + tone + policy + tool catalog
                               + component registry + profile summary
                 ▼
            on-device model ──► FunctionCallResponse(name, args)
                 │                       │
                 │                       ▼
                 │              TurnPipeline.onToolCall
                 │                ├─ finance tools ──► InputProvenanceGuard: args must trace to
                 │                │     the user, the profile or a prior result, else refused
                 │                │                 ──► FinanceToolHandlers (advisor_core)
                 │                │                     └─► vehicle_finance ──► ToolResult(id, json)
                 │                ├─ update_profile ──► BuyerProfile.applyUpdate
                 │                ├─ find_vehicles ───► ExternalTools → SearchService / ListingStore
                 │                ├─ read_page ───────► BrowserService.readPage
                 │                └─ present ─────────► PresentRequest.validate ──► SurfaceNotifier
                 │                       │
                 │   Message.toolResponse(result.toModelJson()) ◄──┘
                 ▼
            on-device model ──► TextResponse tokens (narration)
                 ▼
            auto-present: any computed result the model did not present gets its default card
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

- `AdvisorTools.all`: the eleven tool specifications with JSON schemas; descriptions say *when*
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

## 6b. The stage (DD principle 2, realized 2026-10-05)

The content area above the conversation is the **stage**: components presented while the
Motormind is docked land there, newest first, and the chat below is commentary. A result
re-presented with a richer component replaces its card. In fullscreen, cards sit inline.
The app itself acts without waiting for the model: the filters card and a mode-specific
starter join the conversation the moment a shopping mode is chosen, and every finance
result goes on the stage the instant its
tool returns. Interaction prompts (choice, form) stay in the conversation.

## 6c. Turn control

Replies are capped at 400 tokens and tool turns at four. The panel shows elapsed time and a
Stop button during a turn (`stopGeneration()` underneath). An idle watchdog cancels a turn
that produces no event for 75 s. These numbers are emulator-era and become catalog fields
once measured on a device (TQ60).

## 7. The Motormind surface (VA-2.1, Q8)

Three states, one widget tree, a toggle control the user owns:

```
 collapsed (bubble)  ◄──────────────────────────────────────────┐
     │ tap bubble / new reply                                   │ "back" / collapse
     ▼                                                          │
 docked (the split follows the display decision: 15, 33, 55 or 66 percent to the stage)  ──── present(fullscreen) ────►  fullscreen (breakdowns)
     ▲      drag up past threshold                              │
     └──────────────────────── drag down / back ────────────────┘
```

- A persistent **expand/contract control** (the "</>"-style toggle, Q8) cycles the surface
  and can **pin** it; while pinned, `present` requests update content but not the surface.
- The content area owns the space above the sheet and resizes with it; a web page in it can
  be zoomed independently.
- Keyboard insets are handled at the scaffold so the input never hides.

## 8. Interaction model, shopping mode and conversation (Q9, Q16, Q17, Q28–Q30, Q34)

- **Structured first.** When the answer is one of a few options or a number, Motormind
  presents a `choice`, `multi_choice` or `input_form` rather than asking in prose. Fewer
  tokens, faster turns, exact values. Every such prompt carries an implicit "something
  else" that opens free text; the global toggle lets the user expand or collapse the
  Motormind at any time. The person is never trapped in the model's options.
- **Shopping mode, not tone.** `BuyerProfile.mode` is one of browsing (just looking),
  dreaming (dream car, for fun), practical, buying (buying now, detailed budgeting). The
  Motormind infers it from what the user says, may confirm it with a `choice` on the first
  turn, and updates it when intent shifts ("ok, maybe I do want this"). Tone follows mode
  and mirrors the user's register.
- Needs versus wants: items are `unlabeled` unless the user framed them; Motormind may
  ask with a `choice` and the user can ignore it.
- **Conversation titles are dynamic.** A new conversation is titled by time ("Today at
  3:45 PM"); as a vehicle, class or theme surfaces, the title is regenerated from content
  ("My 2015 Civic trade-in", "Sept 3 · SUV shopping"). Never the first message. History
  list newest first, swipe to delete, "new conversation" action. The structured profile is
  shared across conversations; transcripts are per conversation.

## 9. Content area and vehicle discovery (Q7, Q10, Q11, Q15)

- Stage modes today: **Web** (the curated site in `webview_flutter`) and **Cards** (what
  the model or the app presented, listings included). Compare is planned.
- **No sample inventory** (Q41). Listings come from pages the user opens: a **curated site
  list** the project tests, each with an extraction recipe (closer to an HTML pre-rendering
  step than scraping); unknown sites fall back to generic extraction. `find_vehicles`
  searches the listings read so far in this session and earlier ones the user kept. For
  the airplane-mode demo, pages read while online are cached locally and remain usable
  offline (Q40).
- **Browser-assisted data entry** is the core pattern: the user finds a trade-in value,
  insurance quote or listing on a site they trust; the assistant reads the page and offers
  the figures as *inputs* to the finance tools, labeled with the source URL. The app does
  not try to own valuation or total-cost data.
- Reference APIs (NHTSA vPIC, FuelEconomy.gov) fill specs and efficiency, cached locally.

## 10. Browser agent (VA-6, Q20, Q23, TQ18, TQ19, TQ36)

**As built.** `BrowserService` owns one `webview_flutter` WebView on the stage; the site is
chosen on the filters card (EchoPark, Cars.com, Autotrader). `read_page` waits for the
load, probes until the page's cards have rendered, scrolls once the way a person would when
the app itself opened a results page, refuses a human-verification page (reported to the
person; nothing tries to get around it), then reads with the site's **recipe** (a JSON
asset naming the card and field selectors, with a self-check for plausibility; ADR 0007)
and falls back to the generic text patterns when no recipe applies or the self-check fails.
A recipe that fails on a real page is marked broken until a newer one passes. Listings go
into a session `ListingStore`; the live search (`SearchService`) and the model's
`find_vehicles`/`update_search` share one path through it. The **Capture** control saves
the page as rendered, with the recipe's verdict, so real pages reach the tests without the
app ever loading one on its own.

Plan, still the direction:

- Navigation policy: `http(s)` only, downloads and external schemes blocked, JavaScript on.
- `read_page`: inject a Readability-style extraction, strip navigation, ads and headers at
  the DOM level before text extraction, cap to a token budget, return cleaned text plus
  pattern-found price, mileage, year. Long pages: RAG follow-on.
- Presentation of third-party pages in a half screen is a known problem (Q23): options are
  auto-scroll to main content, a reader-mode rendering of the extracted content, or
  fullscreen browser with Motormind collapsed. To be prototyped early.
- Form filling: approved-sites allowlist, per-action preview, explicit confirm, never
  auto-submit, a hard exclusion list (SSN, account and card numbers), and the browser
  disclosure shown at first use.

## 11. Models and delivery (TQ7, TQ10, TQ11)

`docs/MODELS.md` covers candidates. The catalog is a Dart constant today (id, size, URL,
minimum RAM, capabilities); the source is the public litert-community organization on
Hugging Face, with an in-app token field for mirrors or gated entries. The context window
is sized from a memory snapshot at load. *Plan:* an OTA manifest with checksums, a
self-hosted mirror at `motormind.sirisdevelopment.com` (TQ31), a diagnostics screen.

## 12. Build flavors: demo and store (Q22)

Advertising is a **build-time** decision. The `demo` flavor compiles no ad SDK and shows no
slot; the `store` flavor includes a fixed, labeled AdMob banner **across the top** of every
screen, which hides while the keyboard is up (AdMob policy forbids ads adjacent to the
keyboard). *Plan:* a `--dart-define=MOTORMIND_ADS=true` flag plus platform flavors so the ad SDK is
absent from demo binaries; nothing is built yet. Ads never appear inside the chat or inside a result
component, and never affect ranking.

## 13. Privacy, storage, analytics (Q21, TQ21, TQ22)

- Today: secure storage for the Hugging Face token, shared preferences for small flags,
  plain files for captures and recipe overrides. *Plan:* drift (SQLite) for profile,
  conversations and the reference cache.
- Analytics: Firebase Analytics (Q33), anonymous event counts (screen views, tool names
  called, model id, surface transitions, component ids presented, download outcomes), no
  free text, no financial values, opt-in, disclosed in the gate and the terms. The
  Firebase SDK is linked in every build (Dart cannot depend conditionally) and inert unless
  `--dart-define=MOTORMIND_ANALYTICS=true`; the generated Firebase config files identify the
  project and are not secrets.
- *Plan:* a debug network audit that logs every outbound host; a test fails on an
  unexpected host.

## 14. Context budget (learned 2026-10-05)

The first real turn on the emulator overflowed a 4,096-token window: ~870 tokens of system
prompt plus ~2,450 of tool schemas left 445 for the tool result. Everything the model is
told is paid on every turn, so the vocabulary is a performance and layout decision:

| Item | Before | After |
|---|---|---|
| System prompt | ~870 tokens | ~570 |
| Ten tool schemas | ~2,450 | ~1,430 |
| A payment result sent to the model | ~280 | ~115 |
| Gemma 4 E2B context | 4,096 | 8,192 |

Rules that follow: tool descriptions say *when* to call, nothing else; component
descriptions are one clause; results go to the model as rounded outputs and inputs with
assumptions as `key=value`; the full result with assumption prose goes only to the UI.

## 15. Risks and unknowns

- Extraction quality on small models; mitigated by the golden dataset and clarifying
  questions.
- Third-party page presentation in half a screen; prototype early.
- Memory with a 2.4 GB model beside a webview; measure on the Fold 4 and iPhone 15 Pro.
- No toolchain on the development Mac yet; `docs/SETUP.md` is the fix.
- Scraping terms of service on listing sites; user-driven reading in a webview is ordinary
  browsing, automated extraction at scale is not (Q31).
