# Flutter Edge AI

[![pub package](https://img.shields.io/pub/v/flutter_edge_ai.svg)](https://pub.dev/packages/flutter_edge_ai)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

On-device AI for Flutter on Android, iOS, Web, macOS, Windows and Linux. Run any
model a registered engine runs, or the model the operating system already ships,
with text, vision, audio, function calling, embeddings, RAG and speech. No
server, no cloud.

**[Website](https://flutteredge.ai)** ·
**[Docs](https://flutteredge.ai/docs/getting-started)** ·
**[Models](https://flutteredge.ai/docs/models)** ·
**[Codelabs](https://flutteredge.ai/codelabs)** ·
**[pub.dev](https://pub.dev/packages/flutter_edge_ai)**

The core package is small: it installs models and hands them to engines. Every
runtime, store and feature is a separate opt-in package, so an app ships only
what it uses. Start with the [core README](packages/flutter_edge_ai/README.md)
or [Getting started](https://flutteredge.ai/docs/getting-started).

## Packages

| Package | What it does | Docs |
|---|---|---|
| [`flutter_edge_ai`](packages/flutter_edge_ai/README.md) | Core: model installation, the engine registry, sessions and chat. Required by every package except diagnostics and `genkit_hybrid`. | [pub.dev](https://pub.dev/packages/flutter_edge_ai) · [site](https://flutteredge.ai/docs/getting-started) |
| **Engines** | | |
| [`flutter_edge_ai_litertlm`](packages/flutter_edge_ai_litertlm/README.md) | LiteRT-LM (`.litertlm`) through `dart:ffi` on the five native platforms plus web; CPU, GPU and NPU; the LiteRT embedding backend. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_litertlm) · [site](https://flutteredge.ai/docs/litertlm) |
| [`flutter_edge_ai_mediapipe`](packages/flutter_edge_ai_mediapipe/README.md) | MediaPipe (`.task`) on Android, iOS and web. Google's LLM Inference API is maintenance-only; new apps should use `.litertlm`. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_mediapipe) · [site](https://flutteredge.ai/docs/mediapipe) |
| [`flutter_edge_ai_llama`](packages/flutter_edge_ai_llama/README.md) | llama.cpp (`.gguf`) through llamadart on Android, iOS, macOS, Windows, Linux and web; native LoRA. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_llama) · [site](https://flutteredge.ai/docs/llama) |
| [`flutter_edge_ai_onnx`](packages/flutter_edge_ai_onnx/README.md) | ONNX Runtime: GenAI inference and embeddings natively, Transformers.js and onnxruntime-web on web. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_onnx) · [site](https://flutteredge.ai/docs/onnx) |
| [`flutter_edge_ai_builtin_ai`](packages/flutter_edge_ai_builtin_ai/README.md) | The OS model, nothing to download: Gemini Nano (Android), Apple Foundation Models (iOS, macOS), Windows AI Foundry, the browser Prompt API. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_builtin_ai) · [site](https://flutteredge.ai/docs/builtin-ai) |
| **Embeddings and RAG** | | |
| [`flutter_edge_ai_embeddings`](packages/flutter_edge_ai_embeddings/README.md) | Embedding tokenizers (Gemma SentencePiece, BERT WordPiece) for `.tflite` and `.onnx` embedders. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_embeddings) · [site](https://flutteredge.ai/docs/embeddings-and-rag) |
| [`flutter_edge_ai_rag`](packages/flutter_edge_ai_rag/README.md) | On-device RAG: `RagIndex`, embedding profiles, filters and the vector-store contract. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_rag) · [site](https://flutteredge.ai/docs/embeddings-and-rag) |
| [`flutter_edge_ai_sqlite`](packages/flutter_edge_ai_sqlite/README.md) | SQLite (`sqlite-vec`) vector store on every platform, web included. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_sqlite) · [site](https://flutteredge.ai/docs/embeddings-and-rag) |
| [`flutter_edge_ai_qdrant`](packages/flutter_edge_ai_qdrant/README.md) | Qdrant Edge vector store on native platforms. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_qdrant) · [site](https://flutteredge.ai/docs/embeddings-and-rag) |
| **Speech, agents, diagnostics** | | |
| [`flutter_edge_ai_speech`](packages/flutter_edge_ai_speech/README.md) | Speech-to-text, text-to-speech and the `VoiceSession` voice loop. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_speech) · [site](https://flutteredge.ai/docs/speech) |
| [`flutter_edge_ai_agent`](packages/flutter_edge_ai_agent/README.md) | Agent skills (`SKILL.md`) the model picks and runs: text, JS, native intents and MCP tools. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_agent) · [site](https://flutteredge.ai/docs/agent) |
| [`flutter_edge_ai_diagnostics`](packages/flutter_edge_ai_diagnostics/README.md) | Process memory diagnostics on Android, iOS, macOS, Linux and Windows. | [pub.dev](https://pub.dev/packages/flutter_edge_ai_diagnostics) · [site](https://flutteredge.ai/docs/diagnostics) |
| **Genkit** | | |
| [`genkit_flutter_edge_ai`](packages/genkit_flutter_edge_ai/README.md) | Genkit Dart plugin: on-device models and embedders as Genkit models. | [pub.dev](https://pub.dev/packages/genkit_flutter_edge_ai) · [site](https://flutteredge.ai/docs/genkit) |
| [`genkit_hybrid`](packages/genkit_hybrid/README.md) | Hybrid routing for Genkit: on-device and cloud models behind one routing policy. Depends only on `genkit`. | [pub.dev](https://pub.dev/packages/genkit_hybrid) · [site](https://flutteredge.ai/docs/genkit) |

Which package you need for which task, and how they fit together:
[Packages](https://flutteredge.ai/docs/packages) and
[Capabilities](https://flutteredge.ai/docs/capabilities).

## Maintainers

| Maintainer | Looks after |
|---|---|
| Sasha Denisov ([@DenisovAV](https://github.com/DenisovAV)) | Lead maintainer: the core API, the engines, the native builds and every release |
| Jhin Lee ([@leehack](https://github.com/leehack)) | [`flutter_edge_ai_llama`](packages/flutter_edge_ai_llama/README.md) |
| Francesco Vezzani ([@kekko7072](https://github.com/kekko7072)) | [`flutter_edge_ai_builtin_ai`](packages/flutter_edge_ai_builtin_ai/README.md) |
| Samarthsinh Vala ([@samarthsinh2660](https://github.com/samarthsinh2660)) | [`flutter_edge_ai_diagnostics`](packages/flutter_edge_ai_diagnostics/README.md) |
| Daisuke Majima ([@john-rocky](https://github.com/john-rocky)) | The Hugging Face integration: installing a model straight from its repository |

Everyone else who has contributed, and more about each maintainer:
[flutteredge.ai/contributors](https://flutteredge.ai/contributors).

## Repository

- [`packages/`](packages/) — every package above, as one Dart pub workspace.
  The example app with its integration tests is
  [`packages/flutter_edge_ai/example`](packages/flutter_edge_ai/example).
- [`codelabs/`](codelabs/) — the step-by-step apps behind the
  [codelabs](https://flutteredge.ai/codelabs).
- [`website/`](website/) — the source of [flutteredge.ai](https://flutteredge.ai).

More: [Migration guide](packages/flutter_edge_ai/MIGRATION.md) ·
[Desktop support](packages/flutter_edge_ai/DESKTOP_SUPPORT.md) ·
[Contributing](packages/flutter_edge_ai/CONTRIBUTING.md).
The family shipped as `flutter_gemma*` up to core 1.11.4; those names stay
published as they are.

## License

MIT — see [LICENSE](LICENSE).
