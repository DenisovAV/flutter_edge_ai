# Motormind AI

> **Status:** working demo, October 2026. On an Android emulator, Gemma 4 E2B holds a
> conversation, calls the finance tools, reads listing pages through the in-app browser,
> and the app composes the screen from cards, a live filters card and a display decision
> table. Work happens on `develop`.
> Backlog: [BACKLOG.md](BACKLOG.md). Docs: [docs/](docs/README.md).

An on-device AI companion for finding and financing a personal vehicle, built in Flutter.
The language model runs **on the phone**. The financial math runs in **deterministic,
unit-tested Dart**. The app is **a tool, not a salesperson**: it does not sell, lease,
finance or refer, and it is paid by no one for any transaction.

The use case comes from Deloitte's *The AI Dossier* (2026), which describes an "AI assistant
for vehicle buying and leasing": agents that match a buyer to vehicles, analyze total cost
of ownership and lease terms with full transparency, and guide the buyer through a decision
most people find intimidating. [docs/DELOITTE_MAPPING.md](docs/DELOITTE_MAPPING.md) maps
this design to that use case's pillars and trust principles. Motormind AI is not affiliated
with or endorsed by Deloitte. The broader idea the project explores is **UI composed
at runtime from the conversation** rather than pre-designed screens
([ADR 0006](docs/adr/0006-generative-ui.md)).

## What it does

- **Converses** about what the buyer needs, wants and can afford, in a tone the buyer
  picks (practical, stretch, just for fun, detailed budgeting). Income, credit band,
  trade payoff and payment ceiling never leave the device.
- **Computes, never guesses.** Payment, amortization, lease versus buy, trade equity
  including negative equity, affordability warnings and rough cost of ownership come from
  pure Dart functions. The model extracts inputs and explains outputs. Two guards enforce
  it: a narration guard rejects any number the model wrote that no tool returned, and an
  input guard refuses a calculation whose inputs the person never gave, so the model asks
  instead of inventing an income ([ADR 0002](docs/adr/0002-model-never-does-arithmetic.md)).
- **Composes the screen.** The model asks for a component from a registry (payment card,
  fullscreen breakdown, compare, question chips) and a surface (docked or fullscreen); the
  person can override; a pin is planned.
- **Browses with the buyer.** The top of the screen is a web pane showing a curated listing
  site (EchoPark by default). It is the person's browser: they scroll, tap, and answer any
  verification a site shows. The assistant reads only the page they have open, pulls
  listings and figures out of it, and can open a site's filtered results page for a stated
  budget and body style. Figures found on a page become labeled inputs. Reading is a
  per-site JSON recipe with a self-check; a captured page is how a broken recipe gets fixed
  ([ADR 0007](docs/adr/0007-reading-recipes-as-data.md)).
- **Decides the layout at runtime.** Which card is on the stage, whether the filters card
  is open, how much of the screen the page gets: a rules table decides from screen state,
  and a second session of the same model can take the rows over
  ([ADR 0008](docs/adr/0008-display-agent-and-cards-stage.md)).
- **Lets the user pick the model.** A short catalog of on-device models (Gemma 4 E2B
  default), downloaded from the public litert-community catalog, switchable at runtime.
  See [docs/MODELS.md](docs/MODELS.md).
- **Discloses before and during use.** A short disclaimer gate, long-form disclosures one
  tap away, and assumptions beside every number.

Planned, not built: form filling on approved sites with a preview and a confirm every
time; the disclosures on the web; a light model for older phones.

## What it does not do

- Sell, lease, finance, or pass information to any lender or dealer.
- Pull credit or enter Social Security, account or payment details anywhere.
- Quote a rate as fact. Rates are illustrative, dated, labeled and editable.
- Promise anything. Sales language in a reply raises a visible flag.

Advertising, if any, is a build-time flavor with a fixed, labeled slot that never touches
results or ranking. The demo build has none.

## Repository layout

| Path | What it is |
|---|---|
| `apps/motormind/packages/vehicle_finance/` | Pure Dart finance engine with tests |
| `apps/motormind/packages/advisor_core/` | Pure Dart tool specs, finance tool handlers, narration guard, policy check, disclosures, buyer profile, component registry; with tests |
| `apps/motormind/` | The Flutter app: conversation, stage and cards, live search and filters, web pane with reading recipes and captures, model catalog (Riverpod 3, go_router) |
| `packages/` | Upstream `flutter_edge_ai` packages: inference engines, agent loop, speech, RAG, diagnostics |
| `docs/` | Architecture, setup, models, decisions ([index](docs/README.md)) |
| `BACKLOG.md` | Epics, features and user stories |

This repository is a trimmed fork of [DenisovAV/flutter_edge_ai](https://github.com/DenisovAV/flutter_edge_ai)
(formerly `flutter_gemma`), the on-device LLM toolkit for Flutter.
[docs/UPSTREAM.md](docs/UPSTREAM.md) explains the relationship.

## Building and running

Toolchain install is in [docs/SETUP.md](docs/SETUP.md). The two Dart packages run on the
Dart VM alone; the app's widget tests need Flutter.

```bash
cd apps/motormind/packages/vehicle_finance && dart pub get && dart test
```

```bash
cd apps/motormind/packages/advisor_core && dart pub get && dart test
```

```bash
cd apps/motormind && flutter pub get && flutter analyze && flutter test
```

Running on a device or emulator, including the emulator GPU modes the web pane needs, is
in [docs/SETUP.md](docs/SETUP.md).

## Attribution and license

Upstream `flutter_edge_ai` is MIT licensed, copyright Sasha Denisov. See [LICENSE](LICENSE).
Project-specific code and documentation are by James Baker, built with AI coding
assistance; the architecture, product decisions and review are his.
