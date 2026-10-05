# Motormind AI

> **Status:** first working loop, October 2026. On an Android emulator, Gemma 4 E2B takes a
> typed sentence, calls the finance tools, and the app shows the computed payment and
> trade-equity cards. Work happens on `develop`.
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
  user can override and pin.
- **Reads the web for the buyer.** An in-app browser the assistant can read from, with a
  curated list of tested listing and valuation sites. Figures found on a page become
  labeled inputs. Form filling only on sites the user approved, previewed and confirmed
  every time.
- **Lets the user pick the model.** A short catalog of on-device models (Gemma 4 E2B
  default, Qwen3 0.6B light, OS built-in where available), delivered over the air with
  checksums, switchable at runtime. See [docs/MODELS.md](docs/MODELS.md).
- **Discloses before and during use.** A short disclaimer gate, long-form disclosures one
  tap away and on the web, and assumptions beside every number.

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
| `apps/motormind/` | The Flutter app (scaffold; Riverpod 3, go_router, workspace member) |
| `packages/` | Upstream `flutter_edge_ai` packages: inference engines, agent loop, speech, RAG, diagnostics |
| `docs/` | Architecture, setup, models, decisions ([index](docs/README.md)) |
| `BACKLOG.md` | Epics, features and user stories |

This repository is a trimmed fork of [DenisovAV/flutter_edge_ai](https://github.com/DenisovAV/flutter_edge_ai)
(formerly `flutter_gemma`), the on-device LLM toolkit for Flutter.
[docs/UPSTREAM.md](docs/UPSTREAM.md) explains the relationship.

## Building and running

Toolchain install is in [docs/SETUP.md](docs/SETUP.md). Until the app scaffold exists, the
runnable parts are the two Dart packages:

```bash
cd apps/motormind/packages/vehicle_finance && dart pub get && dart test
```

```bash
cd apps/motormind/packages/advisor_core && dart pub get && dart test
```

## Attribution and license

Upstream `flutter_edge_ai` is MIT licensed, copyright Sasha Denisov. See [LICENSE](LICENSE).
Project-specific code and documentation are by James Baker, built with AI coding
assistance; the architecture, product decisions and review are his.
