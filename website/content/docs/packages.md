---
title: Packages
description: Modular inference, embedding, speech, RAG orchestration, and storage packages for Flutter Edge AI.
image: https://flutteredge.ai/images/og-image.png
---

The former `flutter_gemma` monolith is now a set of opt-in modules. Core owns
model installation plus inference, embedding, and speech registries. Since 2.0,
RAG orchestration has its own instance-scoped package and storage providers
depend on it. Apps ship only the runtimes and vector stores they use.

## The packages

| Package | What it does | Platforms |
|---|---|---|
| **`flutter_edge_ai`** | Core — registry, contracts, model management, sessions, chat. No engine on its own. **Always required.** | All |
| **`flutter_edge_ai_litertlm`** | `.litertlm` inference via `dart:ffi` (LiteRT-LM C API). Owns the shared native library. | Mobile + Desktop + Web |
| **`flutter_edge_ai_mediapipe`** | `.task` / `.bin` inference via MediaPipe. | Mobile + Web |
| **`flutter_edge_ai_builtin_ai`** | System OS models — Gemini Nano (Android / AICore), Apple Foundation Models (iOS 26+/macOS), Windows AI Foundry (Phi Silica), and Gemini Nano via the Chrome Prompt API (Web). No model file to bundle or download. A thin adapter over [`flutter_local_ai`](https://pub.dev/packages/flutter_local_ai), which owns the native layer — not a plugin itself. | Android + iOS + macOS + Windows + Web |
| **`flutter_edge_ai_onnx`** | Text generation (`OnnxEngine`) + embeddings (`OnnxEmbeddingBackend`) — ORT-GenAI/ORT via `dart:ffi` on native, Transformers.js/onnxruntime-web on Web. | macOS, Linux, Windows, Android, iOS (arm64) + Web |
| **`flutter_edge_ai_embeddings`** | Embedding tokenizer implementations (Gemma SentencePiece, BERT WordPiece), registered via `embeddingTokenizers:`. Needs a backend — `LiteRtEmbeddingBackend` (`flutter_edge_ai_litertlm`) or `OnnxEmbeddingBackend` (`flutter_edge_ai_onnx`). | All |
| **`flutter_edge_ai_rag`** | Instance-scoped RAG orchestration, `RagIndex`, stable embedding profiles, filters, and vector-store provider contracts. | All |
| **`flutter_edge_ai_qdrant`** | qdrant-edge provider for `flutter_edge_ai_rag`, via the official qdrant_edge UniFFI SDK. Fastest on native. | Native (no Web) |
| **`flutter_edge_ai_sqlite`** | SQLite + `sqlite-vec` provider for `flutter_edge_ai_rag`. Exact + portable. | All (incl. Web) |
| **`flutter_edge_ai_agent`** | On-device [agent skills](/docs/agent) — SKILL.md catalog + tool-calling loop (text / JS / native-intent / MCP). | Native, no Web (JS skills: no Linux) |
| **`flutter_edge_ai_speech`** | On-device [speech](/docs/speech) — speech-to-text + text-to-speech + a `VoiceSession` voice loop (moonshine/Whisper/Parakeet STT + Matcha/Qwen3/Inflect TTS) via the LiteRT C API + `dart:ffi`. | Native (no Web) |
| **`flutter_edge_ai_diagnostics`** | [Memory diagnostics](/docs/diagnostics) — the anonymous footprint (the memory the OS cannot reclaim) and the memory still available, read from the OS. No native code, no dependency on core. | Android + iOS |

## How it works

- **Core registers no AI runtime by itself.** Wire inference, embedding,
  tokenizer, and speech packages through `FlutterEdgeAi.initialize(...)`.
- **RAG is independently owned.** Create `FlutterEdgeAiRag(providers:)`, open
  one or more profile-bound indexes, and dispose them before core/custom embedders.
  See [Embeddings & RAG](/docs/embeddings-and-rag).
- **Probe-chain registry.** Engines and backends are pure factories that declare
  `canHandle(spec)` + a priority. The registry selects a provider per model by
  declared `ModelFileType` — `task` / `binary` → MediaPipe, `litertlm` → LiteRT-LM,
  `onnx` → Onnx, `builtIn` → BuiltInAi.
- **One app can run both formats.** Register both `LiteRtLmEngine()` and
  `MediaPipeEngine()`, and the registry routes each model to the engine that
  handles its declared `ModelFileType` — not its file extension.
- **Shared native library.** `flutter_edge_ai_litertlm` owns the native LiteRT
  library (fetched at build time via its Native-Assets hook), and
  `flutter_edge_ai_speech` has no hook of its own and consumes that bundle
  transitively. `flutter_edge_ai_embeddings` touches no native library at all. `flutter_edge_ai_onnx` owns its own separate ORT / ORT-GenAI
  native archives.

## Choosing packages

| You want to… | Add |
|---|---|
| Run `.litertlm` models (Gemma 4, Qwen3, FastVLM, + all desktop) | `flutter_edge_ai_litertlm` |
| Run `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4) | `flutter_edge_ai_mediapipe` |
| Run the OS system model with no download (Gemini Nano / Apple FM / Windows AI Foundry) | `flutter_edge_ai_builtin_ai` |
| Run ONNX models — ORT-GenAI (native) or Transformers.js (Web) | `flutter_edge_ai_onnx` |
| Generate text embeddings | `flutter_edge_ai_embeddings` + `flutter_edge_ai_litertlm` (`LiteRtEmbeddingBackend`) |
| Generate text embeddings from ONNX/ORT models | `flutter_edge_ai_embeddings` + `flutter_edge_ai_onnx` (`OnnxEmbeddingBackend`) |
| On-device RAG on native, fastest (Android/iOS/desktop) | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| On-device RAG on web, or a portable/exact store on any platform | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` |
| On-device agent skills the model runs itself (text / JS / native-intent / MCP) | `flutter_edge_ai_agent` |
| Transcribe audio, synthesize speech, or run a voice loop on-device (STT + TTS + voice) | `flutter_edge_ai_speech` |
| Measure what a model costs in memory the OS cannot reclaim (Android + iOS) | `flutter_edge_ai_diagnostics` |

<Info>
Desktop is served **primarily** by [`flutter_edge_ai_litertlm`](/docs/litertlm)
(`.litertlm`) — the default engine. [`flutter_edge_ai_onnx`](/docs/onnx) also runs
on all three desktop OSes (macOS/Windows/Linux), and the OS built-in model is
available via [`flutter_edge_ai_builtin_ai`](/docs/builtin-ai) on **macOS** (Apple
Foundation Models) and on **Windows** (AI Foundry — nothing to configure to
build: `flutter_local_ai` resolves the Windows App SDK projection itself; running
needs Windows 11 25H2+ on Copilot+-class hardware and a packaged app); not on
Linux. There is no MediaPipe engine on
desktop. See [Desktop Support](/docs/desktop).
</Info>

See [Migration](/docs/migration) for the rename and the 2.0 extraction of RAG
from core.

## ONNX Runtime engine

`flutter_edge_ai_onnx` adds a second inference/embedding stack alongside
LiteRT-LM and MediaPipe: **ONNX Runtime** — `dart:ffi` on native (no JVM, no
gRPC), Transformers.js / onnxruntime-web on Web. Two independent arms, either
can be registered on its own:

- **`OnnxEngine`** — text generation via [ORT-GenAI](https://github.com/microsoft/onnxruntime-genai)
  on native, [Transformers.js](https://huggingface.co/docs/transformers.js) on
  Web. Text-only, greedy decoding, one session at a time in v1 — no vision, no
  audio, no LoRA yet.
- **`OnnxEmbeddingBackend`** — embeddings via plain ONNX Runtime
  (WordPiece/BERT-style and SentencePiece models) on native, onnxruntime-web
  on Web, priority 10 over `LiteRtEmbeddingBackend`'s catch-all priority 0.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [OnnxEngine()],
  embeddingBackends: [OnnxEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
);
```

**Platform support:** device-verified via `dart:ffi` on macOS (Apple Silicon),
Linux x64, Windows x64, Android (arm64), and iOS (arm64). On **Web**,
`OnnxEngine` runs generation through Transformers.js v4 and
`OnnxEmbeddingBackend` runs through onnxruntime-web (WebGPU/WASM) — same
public API as native, no `if (kIsWeb)` needed in app code.

<Info>
On native, an ORT-GenAI model installs as a **directory**, not a single file:
`genai_config.json` + `model.onnx` (+ `model.onnx_data` for external weights)
+ tokenizer files. `fromHuggingFace(repo)` downloads the whole bundle (the ONNX
resolver picks a CPU execution-provider folder), or ship it yourself as an asset
/ local directory and install with `fromFile(genai_config.json)`. On **Web** this
doesn't apply — the model is identified by its
Hugging Face repo URL (`https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct`),
from which the repo id is derived, not by a directory, and install is fileless: `ModelFileType.onnx` just marks it active,
and Transformers.js downloads and caches the repo itself.
</Info>

See the [`flutter_edge_ai_onnx` README](https://pub.dev/packages/flutter_edge_ai_onnx) for the full platform matrix and FFI details.

## Genkit integration

Two companion packages integrate flutter_edge_ai with [Genkit](https://pub.dev/packages/genkit), Google's framework for building AI features:

| Package | What it does | Depends on |
|---|---|---|
| **`genkit_flutter_edge_ai`** | Exposes flutter_edge_ai as a Genkit model/embedder provider — call `ai.generate(model: flutterEdgeAi.model(...))` and `ai.embed(...)` through the standard Genkit API. | `flutter_edge_ai` + `genkit` |
| **`genkit_hybrid`** | Provider-agnostic hybrid routing: combine an on-device and a cloud model behind one routing policy, with correct streaming + before-first-token fallback. | `genkit` only (no flutter_edge_ai) |

See [Genkit](/docs/genkit) for setup and examples.
