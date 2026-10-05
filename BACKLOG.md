# Motormind AI — Backlog

Organized the way a Jira project would be: **Epics** → **Features** → **User Stories**.
IDs are stable (`VA-3.2` is Epic 3, Feature 2; `VA-3.2.1` its first story). Revised
2026-10-04 after the second question round; scope is prioritized rather than timeboxed (Q3).

Conventions:

- **Priority:** `P0` the concept does not demo without it · `P1` needed for a credible
  demo · `P2` stretch · `P3` store release only.
- **Status:** `done (commit)`, `in progress`, or blank.
- Stories are *As a … I want … so that …* with acceptance criteria (AC).
- "Buyer" is the end user. "Advisor" is the on-device assistant.
- `Q#` / `TQ#` reference the questions log kept outside the repo.

Priority order of epics: VA-0, VA-3, VA-4, VA-1, VA-2, VA-11, VA-5, VA-6, VA-7, VA-9,
VA-10, then VA-8 and VA-12.

---

## Epic VA-0 — Project foundation

### VA-0.1 Repository shape (P0)

- **VA-0.1.1** As a maintainer, I want the app at `apps/motormind/` as a pub workspace
  member, so that it consumes the local `flutter_edge_ai` packages and I can patch them.
  AC: root `flutter pub get` resolves the app. (ADR 0005)
- **VA-0.1.2** As a maintainer, I want the fork trimmed of upstream's codelabs, website,
  tooling, workflows and agent files on `develop`, so that a reviewer sees the app first.
  **done**
- **VA-0.1.3** As a maintainer, I want `AGENTS.md`/`CLAUDE.md` to describe this project's
  rules. **done**
- **VA-0.1.4** As a maintainer, I want `docs/` tracked and `.fvm/` ignored. **done**
- **VA-0.1.5** As a maintainer, I want the two pure-Dart packages outside the workspace so
  `dart test` needs no Flutter. AC: each has its own `pubspec.yaml` without
  `resolution: workspace`. **done**

### VA-0.2 Toolchain and CI (P0)

- **VA-0.2.1** As a developer, I want a documented toolchain install (FVM, Flutter, Android
  arm64 emulator, Xcode, CocoaPods). AC: `docs/SETUP.md`; `flutter doctor` green. **done** (Flutter 3.47.6 at ~/flutter)
- **VA-0.2.2** As a developer, I want CI to format-check, analyze and test the pure
  packages and (once it exists) the app on every push to `develop`. AC:
  `.github/workflows/motormind-ci.yml` green. *workflow written; unverified*
- **VA-0.2.3** As a developer, I want an Android debug APK from CI so a reviewer can
  install without building. (P1)

### VA-0.3 App scaffold (P0)

- **VA-0.3.1** As a developer, I want a Material 3 app with go_router, Riverpod 3, build
  flavors (`demo`, `store`) and the feature-first layout in `docs/ARCHITECTURE.md`. AC: app
  boots to the disclosure gate then a placeholder home. **done except flavors** (ADR 0003, 0004)
- **VA-0.3.2** As a developer, I want `vehicle_finance` and `advisor_core` with real tests.
  **done** (31 + 27 tests passing)

---

## Epic VA-3 — Financial engine (deterministic)

### VA-3.1 Core calculators (P0) — **done**

- **VA-3.1.1** monthly payment from principal, APR, term (0% handled). **done**
- **VA-3.1.2** maximum principal for a payment ceiling. **done**
- **VA-3.1.3** amortization schedule that sums exactly. **done**
- **VA-3.1.4** trade equity including negative equity, rolled in or paid in cash. **done**
- **VA-3.1.5** full purchase estimate: tax (with optional trade credit), fees, down, trade,
  cash at signing, amount financed, payment, total cost. **done**

### VA-3.2 Credit and constraints (P0)

- **VA-3.2.1** credit bands, numeric score mapped to a band, JSON-loadable illustrative APR
  table with source and date. **done with PLACEHOLDER values** (TQ12 follow-up: real
  sourced table)
- **VA-3.2.2** payment-to-income, debt-to-income and term warnings; never blocking.
  **done**

### VA-3.3 Lease and ownership (P1)

- **VA-3.3.1** lease payment from cap cost, residual, money factor, cap reduction, monthly
  tax; money factor to APR. **done**
- **VA-3.3.2** rough cost of ownership from labeled tables (depreciation, fuel or energy,
  insurance band, maintenance, taxes and fees). **done with PLACEHOLDER tables**
- **VA-3.3.3** As a buyer, I want the advisor to prefer figures I found on a site I trust
  (insurance quote, valuation) over the rough tables, so that estimates reflect my
  vehicle. AC: tool inputs override table values and are labeled with the source. (Q15,
  Q11)

### VA-3.4 Explanations (P0)

- **VA-3.4.1** every result carries inputs and assumptions. **done**
- **VA-3.4.2** three what-if variants per deal. **done**

### VA-3.5 Presentation variants (P2)

- **VA-3.5.1** As a buyer who wants the technical view, I want a toggle to a TILA-style
  layout (amount financed, finance charge, total of payments) with its own disclaimer, so
  that I can compare to a lender's paperwork. (Q19)

### VA-3.6 New-vehicle extras (P2)

- **VA-3.6.1** As a buyer looking at new vehicles, I want incentives and cash-back entered
  as inputs that reduce price or financed amount, so that new-car math is right. (Q6)

---

## Epic VA-4 — Trust, safety and disclosures

### VA-4.1 Disclosures (P0)

- **VA-4.1.1** disclosure wording registry with versions. **done** (`Disclosures`)
- **VA-4.1.2** As a buyer, I want a short disclaimer gate before first use that I
  acknowledge, with a link to the full text, so that I know what this is. AC: shown once per
  `gateVersion`; acknowledgement stored locally. **done** (widget-tested)
- **VA-4.1.3** As a buyer, I want the full disclosures in-app from every screen and on a
  public web page, so that they are permanent. AC: app-bar entry **done**; GitHub Pages
  publication of `docs/DISCLOSURES.md` pending (Q36).
- **VA-4.1.4** As a buyer, I want a short disclaimer and an assumptions link on every
  financial component.

### VA-4.2 Numbers from tools only (P0)

- **VA-4.2.1** narration guard with tolerance rules and tests. **done**
- **VA-4.2.2** As a developer, I want the guard wired into the turn: one regeneration with a
  stricter instruction, then a templated sentence plus the card. **done** (scripted-driver
  tests)
- **VA-4.2.5** As a buyer, I want the advisor refused from calculating with numbers I never
  gave, so that a card never rests on an invented income or price. **done**
  (`InputProvenanceGuard`; observed and fixed on the emulator 2026-10-05)
- **VA-4.2.3** As a developer, I want components to render only from tool results. AC: no
  component takes model text for a numeric field.
- **VA-4.2.4** As a developer, I want to experiment with the "never emit digits" constraint
  and compare it to the guard on the golden set. (P2, TQ14)

### VA-4.3 Non-salesperson policy and tone (P0)

- **VA-4.3.1** policy check for urgency, guarantees, pressure, advice, compensation.
  **done**
- **VA-4.3.2** As a buyer, I want a visible banner when a reply tripped the policy check,
  while still seeing the reply, so that the tool is honest about itself. **done**
- **VA-4.3.3** As a buyer, I want the advisor to recognize how I am shopping (browsing,
  dreaming, practical, buying), confirm it with a tappable choice when unsure, and shift when
  my intent shifts, so that its tone matches me. AC: `ShoppingMode` in profile **done**;
  persona prompt adapts; advisor mirrors register. (Q16, Q30)
- **VA-4.3.4** As a buyer, I want the advisor to say what it does not know rather than fill
  gaps. AC: evaluation prompts in `advisor_core/test/`.

### VA-4.4 Evaluation (P1)

- **VA-4.4.1** As a developer, I want a golden dataset of 30+ buyer utterances with
  expected extraction, so that models can be scored. AC: JSON lines; a harness reports
  accuracy per model. (TQ16, TQ37)

---

## Epic VA-1 — On-device LLM runtime and model management

### VA-1.1 Engine bootstrap (P0)

- **VA-1.1.1** `AdvisorModelService` wrapping initialize, install, `getActiveModel`,
  session lifecycle; the rest of the app never touches the SDK. **done** behind an
  `EdgeAiGateway` seam with a fake for tests; chat session wiring pending.
- **VA-1.1.2** full conversation flow works in airplane mode once a model is installed.
  **works on the emulator with networking on**; airplane-mode check pending on the Fold 4.

### VA-1.2 Catalog and switching (P1)

- **VA-1.2.1** As a buyer, I want to choose from a short list of models with size, capability
  and device fit, and switch without restarting. **catalog, Models screen and switching
  done**; device-fit check pending. (TQ7)
- **VA-1.2.2** OS built-in models offered when the availability probe succeeds. Documented
  only; the Fold 4 has no AICore (TQ42). (P2)
- **VA-1.2.3** two-model mode (extractor + narrator) behind the same session interface.
  (P2, TQ8)

### VA-1.3 OTA model delivery (P1)

- **VA-1.3.1** As a buyer, I want download with progress, free-space check, retry and
  checksum verification. **progress, cancel, retry done**; free-space and checksum pending.
- **VA-1.3.2** As a buyer, I want in-app Hugging Face token entry for gated models or a
  private mirror. **done** (secure storage). Neither catalog model needs one.
- **VA-1.3.3** As a maintainer, I want a remote model manifest (id, size, SHA-256, URL,
  minimum RAM, capabilities) hosted at `motormind.sirisdevelopment.com`, so models can be
  added or mirrored without an app release. (TQ31)

### VA-1.4 Measurement (P1)

- **VA-1.4.1** As a reviewer, I want an in-app diagnostics screen reporting cold start,
  time to first token, tokens per second, peak memory and extraction score, exportable as
  JSON, so that `docs/MEASUREMENTS.md` is real. Optional upload. (TQ11)

---

## Epic VA-2 — Conversation experience

### VA-2.1 Adaptive advisor surface (P0)

- **VA-2.1.1** collapsed bubble with unread indicator.
- **VA-2.1.2** docked bottom sheet (30–60%) with the content area above.
- **VA-2.1.3** fullscreen for breakdowns with an explicit way back.
- **VA-2.1.4** a persistent expand/contract toggle the user owns, with pin; the model's
  `present` is a request. **state machine and toggle done**; pin UI pending (Q8)
- **VA-2.1.5** state machine as a Riverpod notifier **done**; transitions animated and
  keyboard-safe pending.
- **VA-2.1.6** As a buyer, I want the split between content, advisor and keyboard to adapt
  to what is being shown and to what I am doing (typing, reading a page, reviewing a
  breakdown), so that the chat area is never a fixed size. AC: layout allocator with model
  priority hints; keyboard-up rule shows the thing being answered. (Q29)

### VA-2.2 Chat (P0)

- **VA-2.2.1** streamed replies with stop. **streaming done**; stop pending.
- **VA-2.2.2** tool activity shown as status chips. **done**
- **VA-2.2.3** `choice`, `multi_choice` and `input_form` interaction components with the
  implicit "something else" escape, so the advisor asks with options and forms rather than
  prose. **registry and validation done**; widgets pending.

### VA-2.3 Conversation history (P1)

- **VA-2.3.1** As a buyer, I want a "new conversation" action and a history list, so that
  I can start over or return. AC: transcripts persisted per conversation; profile shared.
  (Q9)
- **VA-2.3.2** As a buyer, I want conversation titles that start as a time ("Today at 3:45
  PM") and become descriptive from content ("My 2015 Civic trade-in", "Sept 3 · SUV
  shopping"), never the first message, so that the list is useful on a small screen. (Q34)

### VA-2.4 Voice (P2)

- **VA-2.4.1** push-to-talk and optional spoken replies via `flutter_edge_ai_speech`. (Q12)

---

## Epic VA-11 — Dynamic design (the core idea, ADR 0006)

The concept, principles and numbered requirements (`DD-R#`) live in the working document
`DYNAMIC_DESIGN.md` outside the repo until it stabilizes. Stories here reference them.

### VA-11.1 Component registry (P0)

- **VA-11.1.1** registry and `present` validation in `advisor_core`, including interaction
  components, props validation and `highlights`. **done**
- **VA-11.1.2** As a developer, I want Flutter widgets for each registered component,
  each rendering from a `ToolResult`, so that the model can compose any of them. **payment
  summary, breakdown, trade equity, choice, form done**; gauge, lease, ownership, vehicle
  cards generic for now.
- **VA-11.1.4** As a developer, I want a computed result the model forgot to present shown
  anyway with its default component. **done**
- **VA-11.1.3** As a buyer, I want the screen to change shape with the conversation (one
  card, a breakdown, a compare, a question), so that nothing is pre-designed. AC: the same
  conversation demonstrably yields different compositions.

### VA-11.2 Layout allocation, control and situation (P1)

- **VA-11.2.0** As a buyer, I want the split between content and conversation to follow what
  is being shown and asked, the keyboard, and the screen's shape, so that nothing I am
  deciding about is hidden. AC: allocator with keyboard rule and decision rule (DD-R6–R8);
  viewport descriptor passed to the model (DD-R10); wide screens side-by-side (DD-R9).
  **keyboard rule done** (unverified: the emulator has no real keyboard); rest pending.
- **VA-11.2.4** As a buyer, I want the reorganize control and a pin, and every structured
  prompt minimizable, so that I am never trapped. (DD-R11–R13)
- **VA-11.2.5** As a buyer returning to the app, I want a short orientation and a "continue
  here" option, so that I remember where I was. (DD-R14, Q43)
- **VA-11.2.6** As a buyer, I want stale listings marked and current alternatives offered,
  so that I am not shown cars that are gone. (DD-R15, Q45)
- **VA-11.2.7** As a buyer, I want the empty content area to show something the advisor
  chose for me (recent conversations, what it can help with, profile or garage completion),
  not a fixed screen. (DD-R16, Q44)

- **VA-11.2.1** As a developer, I want `present` choices logged (component, surface, timing)
  so the model picker can score how well each model uses the registry.
- **VA-11.2.2** constrained layout (`stack`, `row`, `compare`) whose leaves are registry
  components, with size and priority hints. (P1, promoted per Q28)
- **VA-11.2.3** free-layout experiment: give the model a constrained canvas and find where
  usability breaks; record results in `docs/MEASUREMENTS.md`. (P2, Q28)

---

## Epic VA-5 — Vehicle discovery and content

### VA-5.1 Profile (P1)

- **VA-5.1.1** buyer profile with user-labeled needs and wants, `update_profile` tool.
  **done**
- **VA-5.1.2** As a buyer, I want to see and edit my profile and relabel items, so that the
  advisor never decides what I need. (Q17)
- **VA-5.1.3** As a buyer, I want conflicts between wants, needs and budget shown with the
  numbers that drive them.

### VA-5.2 Data sources (P1)

- **VA-5.2.1** ~~bundled sample inventory~~ dropped (Q41). Replaced by: listings read from
  pages are kept per session and optionally saved; `find_vehicles` searches them; pages read
  online stay usable offline for the airplane-mode demo (Q40).
- **VA-5.2.2** a curated, tested list of listing and valuation sites with extraction
  recipes (an HTML pre-rendering step, not scraping); unknown sites fall back to generic
  extraction. The browser is a capability the advisor uses, not a feature the app sells
  (Q44). (Q10, Q31)
- **VA-5.2.3** NHTSA vPIC and FuelEconomy.gov adapters, cached, source shown. (TQ17)
- **VA-5.2.4** `ValuationSource` interface with user-entered and browser-assisted
  implementations. (Q11)

### VA-5.3 Content area (P1)

- **VA-5.3.1** vehicle list and detail; selection updates conversation context.
- **VA-5.3.2** compare two or three vehicles including payment and ownership cost.

---

## Epic VA-6 — Browser agent

### VA-6.1 Read-only browsing (P1)

- **VA-6.1.1** in-app webview mode (`flutter_inappwebview`), http(s) only, downloads and
  external schemes blocked. (TQ18)
- **VA-6.1.2** `read_page`: DOM cleanup, readability extraction, token cap, pattern-found
  price, mileage, year; figures flow to finance tools as labeled inputs. (TQ19)
- **VA-6.1.3** As a buyer, I want third-party pages to be usable in half a screen
  (auto-scroll to content, reader mode, or go fullscreen), so that ads and headers do not
  eat the view. AC: prototype on three curated sites. (Q23)

### VA-6.2 Approved form filling (P2)

- **VA-6.2.1** approved-sites allowlist, per-session or permanent, removable.
- **VA-6.2.2** preview and explicit confirm for every submission; contact details only;
  never SSN, account or payment data; browser disclosure shown first. (Q20)

### VA-6.3 Browser-assisted data entry (P1)

- **VA-6.3.1** As a buyer, I want to look up my trade-in value or an insurance quote on a
  site I trust and have the advisor pick the figure off the page and offer it as an input,
  so that I do not retype numbers. AC: works on two curated sites. (Q11, Q15, TQ13)

---

## Epic VA-7 — Privacy and data

- **VA-7.1.1** profile, conversations and inputs stored only on device (drift; secure
  storage for the token). (TQ21)
- **VA-7.1.2** one-action data wipe.
- **VA-7.1.3** Firebase Analytics, anonymous and opt-in, event list disclosed in the gate
  and terms; no free text, no financial values. **plumbing done** (no-op unless
  `MOTORMIND_ANALYTICS` is defined; parameter allow list); project config pending (Q21, Q33)
- **VA-7.1.4** debug network audit; test fails on unexpected hosts. (TQ22)

---

## Epic VA-9 — Quality and release

- **VA-9.1.1** high unit coverage in the pure packages, reported in CI.
- **VA-9.1.2** widget tests for the three surface states and each component.
- **VA-9.1.3** one device integration test: extraction → calculation → narration → present.
- **VA-9.1.4** device matrix recorded: Galaxy Z Fold 4 (12 GB), iPhone 15 Pro (8 GB), an
  arm64 emulator. (TQ20)

---

## Epic VA-10 — Portfolio deliverables

- **VA-10.1.1** README states the architecture decision, the generative-UI idea and the
  measurements.
- **VA-10.1.2** 60–90 second screen recording of the airplane-mode flow.
- **VA-10.1.3** Deloitte mapping page. **done** (`docs/DELOITTE_MAPPING.md`)

---

## Epic VA-8 — Advertising (store flavor only, P3)

- **VA-8.1.1** `demo` and `store` build flavors; the ad SDK is absent from `demo`. (Q22)
- **VA-8.1.2** fixed, labeled AdMob banner across the top of every screen, hidden while the
  keyboard is up; never inside chat or a result component; never affects ranking. (Q32)
- **VA-8.1.3** `docs/POLICY.md`: no compensation tied to any transaction; sponsorships
  revisited later. (Q23)

## Epic VA-13 — Garage (candidate, Q53 / DD-Q5)

- **VA-13.1.1** As a buyer, I want the advisor to keep my current vehicles (year, make,
  model, mileage, payoff, estimated value, which one is the trade) across conversations, so
  that "my Civic" means something and the trade-in flow starts from facts. Pending your
  answer.

## Epic VA-12 — Motorsport vehicles (later)

- **VA-12.1.1** As a buyer, I want motorcycles and other personal motorsport vehicles,
  with their financing norms, so that the tool covers what the dealer group sells. AC:
  `VehicleClass` extended; lease and insurance tables per class. (Q5)
