# vehicle_finance

The deterministic math behind Motormind AI. Pure Dart, no Flutter, no network.

Rules this package enforces (see ADR 0002 in `docs/adr/`):

- Every public function is a pure function of its arguments.
- Every result type extends `CalcResult` and carries the exact `inputs` it used and a list
  of `Assumption`s, each with a source and an "as of" date. UI shows them; the model
  narrates them.
- Rates and tables are **illustrative placeholders** until replaced with sourced values.
  Each table says so in its `source` field.

```bash
dart pub get
dart test
```

| File | What it computes |
|---|---|
| `loan.dart` | monthly payment, maximum principal for a payment, amortization schedule, loan summary |
| `trade.dart` | trade-in equity, including negative equity |
| `deal.dart` | amount financed and a full purchase estimate from price, tax, fees, down, trade |
| `lease.dart` | lease payment from cap cost, residual, money factor; money factor to APR |
| `credit.dart` | credit bands, score to band, illustrative APR table (JSON-loadable) |
| `affordability.dart` | payment-to-income and debt-to-income warnings (never blocks); use `maxPrincipal` in `loan.dart` to turn the suggested payment into a price |
| `ownership.dart` | rough five-year cost of ownership from class-based tables |
| `what_if.dart` | one-variable-at-a-time alternatives to a deal |
| `money.dart` | `roundCents` and `roundTo`, the rounding every caller must share |
| `assumption.dart` | `Assumption`, `CalcResult` and `assumptionsReviewedOn`, the date the bundled defaults were last reviewed |
