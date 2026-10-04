# docs/

Technical documentation for Motormind AI. Upstream `flutter_edge_ai` docs live in
`packages/*/README.md` and at flutteredge.ai; this folder is only for what is specific to
this project.

| Document | Purpose | Status |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Layers, the advisor turn pipeline, generative UI, the surface state machine, data flow | draft, updated 2026-10-04 |
| [SETUP.md](SETUP.md) | Toolchain install on macOS: FVM, Flutter, Android, iOS | ready |
| [MODELS.md](MODELS.md) | On-device model candidates, trade-offs, OTA delivery, switching | ready |
| [DELOITTE_MAPPING.md](DELOITTE_MAPPING.md) | The project mapped to the AI Dossier pillars and trust principles | ready |
| [UPSTREAM.md](UPSTREAM.md) | Fork relationship and what was trimmed | ready |
| [adr/](adr/) | Architecture decision records 0001–0006 | see each |
| `MEASUREMENTS.md` | Per-model, per-device cold start, time to first token, throughput, memory, extraction score | planned (VA-1.4) |
| `PRIVACY.md` | What is stored, where, what leaves the device, what analytics collect | planned (VA-7) |
| `POLICY.md` | Non-salesperson policy, advertising rules, no transaction compensation | planned (VA-8) |
| `DISCLOSURES.md` | The long-form disclosures, also published as the web page the app links to | planned (VA-4.1) |

Upstream's two tracked files, `LEGACY_API.md` and `benchmarks/`, are left in place.
