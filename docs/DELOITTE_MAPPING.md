# Mapping to Deloitte's AI Dossier use case

The project concept comes from the **"AI assistant for vehicle buying and leasing"** entry
in Deloitte's *The AI Dossier* (Consumer sector, Sales, Agentic AI), pages 17 and 18 of the
2026 edition. This page maps the dossier's four "how AI can help" pillars and three "managing
risk and promoting trust" principles to what Motormind builds, and is honest about what it
does not.

## The four pillars

| Dossier pillar | What it describes | Motormind | Where |
|---|---|---|---|
| **Personalized vehicle matching** | A central advisor agent that identifies models matching preferences, budget and usage, whether buying, leasing or CPO | Conversation builds a buyer profile of user-labeled needs and wants plus constraints; deterministic matching over an inventory source explains each match | Epic VA-5 |
| **Comprehensive financial analysis** | A buy agent analyzing total cost of ownership (payments, depreciation, maintenance, taxes) and a lease agent evaluating lease terms, "with full transparency" | The core of the app. Loan, lease, equity, affordability and ownership-cost math in a tested Dart package; every figure shows its inputs and assumptions | Epics VA-3, VA-4 |
| **Inventory and production visibility** | An OEM agent that sees the production pipeline and offers booking when dealer stock does not match | Out of scope for a consumer tool with no OEM feed. Partially covered by reading live listing pages in the browser | Epic VA-6 |
| **Streamlined communication and support** | A communication agent delivering documents, summaries and dealer-system integration | Partially: summaries and exportable breakdowns. Deliberately not integrated with dealer systems, because the tool takes no side in the transaction | VA-2, VA-6.2 |

## The three trust principles

| Dossier principle | Dossier wording (paraphrased) | Motormind design response |
|---|---|---|
| **Transparent and explainable** | Major financial commitments need clear explanations of cost breakdowns, assumptions and trade-offs | Every result carries `inputs` and `assumptions` with a source and date; "what-if" variants show trade-offs; the narration guard keeps explanations tied to computed numbers (ADR 0002) |
| **Robust and reliable** | Errors in matching or financial analysis erode trust; validate against real data and keep updated | The model never computes; pure functions with unit tests do; rate and cost tables are dated and labeled illustrative; a golden dataset scores extraction per model |
| **Responsible and accountable** | Outputs should be positioned as guidance, with customers retaining final responsibility | Disclaimer gate before first use, disclosures always one tap away, no lender or dealer relationship, no compensation from transactions, explicit approval for every web action |

## Where Motormind goes beyond the dossier

- **On-device by design.** The dossier does not say where the agents run. Running the
  assistant on the phone is what makes "your income and credit band never leave the device"
  true, and it is the strongest argument for local inference in this use case.
- **Not a sales channel.** The dossier frames the assistant from the OEM and dealer side
  (conversion, reduced workload). Motormind is on the buyer's side only. That is a product
  stance, not a technical one, and it drives the policy layer.
- **The model composes the screen.** The dossier describes agents; Motormind also lets the
  agent decide what to show and where (ADR 0006), which is the broader idea the project
  exists to explore.
