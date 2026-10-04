# advisor_core

The part of Motormind AI that sits between the on-device model and the app, with no
dependency on either. Pure Dart so it runs under `dart test`.

| Directory | Contents |
|---|---|
| `tools/` | `ToolSpec` declarations (name, description, JSON schema) for every tool the model may call, and `FinanceToolHandlers`, which turns tool arguments into `vehicle_finance` results and back into JSON |
| `guard/` | `NarrationGuard`: every number in the model's reply must appear in this turn's tool results or user inputs |
| `policy/` | `PolicyCheck`: flags sales language, guarantees and urgency in a reply; `Disclosures`: the versioned disclaimer registry |
| `profile/` | `BuyerProfile` with user-labeled needs and wants, constraints and conversation tone |
| `ui/` | `UiSpec`: the component registry and the validated `PresentRequest` the model uses to compose the screen |

The app adapts `ToolSpec` to the inference SDK's `Tool` type in one place, and feeds
`FunctionCallResponse` arguments to `FinanceToolHandlers`. Nothing here knows which model
is running, which is what makes model switching safe.

```bash
dart pub get
dart test
```
