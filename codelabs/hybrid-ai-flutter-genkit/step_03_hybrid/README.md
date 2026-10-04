# Hybrid AI in Flutter: From Cloud to On-Device with Genkit Dart

A codelab showing hybrid AI in Flutter with the [Genkit Dart](https://pub.dev/packages/genkit) framework: streaming from Gemini via `genkit_google_genai`, on-device inference via `genkit_flutter_edge_ai` (LiteRT-LM), cloud↔on-device routing via [`genkit_hybrid`](https://pub.dev/packages/genkit_hybrid) (capability / cost / cascade), multimodal image input, and a RAG pipeline over on-device embeddings.

## Codelab

**📖 Full step-by-step codelab: https://flutteredge.ai/codelabs/hybrid-ai-flutter-genkit/**

Each step is a **directory**, not a branch — open the one you want and run it:

| Directory | What's added |
|--------|-------------|
| `step_00_starter` | Chat UI with echo responses |
| `step_01_cloud_ai` | Cloud chat via `genkit_google_genai` (Gemini 3.7 Flash) |
| `step_02_local_ai` | On-device inference via `genkit_flutter_edge_ai` (Gemma 3 1B, LiteRT-LM) |
| `step_03_hybrid` | `AiEngine` — one Genkit, cloud + local routed by `genkit_hybrid` |
| `step_04_smart_routing` | Smart routing + image (multimodal) input |
| `step_05_embeddings` | On-device embeddings + RAG over a local tourist guide |
| `complete` | The finished app |

## Requirements

- Flutter 3.44 or newer
- A GEMINI_API_KEY from [aistudio.google.com](https://aistudio.google.com)
- A HuggingFace account (for model downloads)
- Android, iOS, macOS, Windows, Linux, or the web
- ~1 GB free disk space

## Quick Start

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/hybrid-ai-flutter-genkit/complete
flutter pub get
flutter run \
  --dart-define=GEMINI_API_KEY=your_key \
  --dart-define=HF_TOKEN=hf_xxx
```

## Key Dependencies

```yaml
genkit: ^0.16.0
genkit_google_genai: ^0.3.1
genkit_flutter_edge_ai: ^0.7.0
flutter_edge_ai: ^2.0.0
flutter_edge_ai_litertlm: ^1.8.7   # LiteRT-LM engine (flutter_edge_ai ships none by default)
flutter_edge_ai_embeddings: ^2.2.2
genkit_hybrid: ^0.2.2
```

## Architecture

One `Genkit` instance with both plugins (`googleAI` + `GenkitFlutterEdgeAiPlugin`), wrapped in an `AiEngine`. Each `PolicyMode` (cloud / local / smart / cascade / budget) is composed by `genkit_hybrid` into an ordinary Genkit `Model`; the chat screen always calls the same `ai.generateStream(...)` and only the resolved model changes with the policy:

```dart
// Cloud (Gemini 3.7 Flash)
ai.generateStream(model: googleAI.gemini('gemini-3.7-flash'), prompt: prompt)

// On-device (Gemma 3 1B via LiteRT-LM)
ai.generateStream(model: flutterEdgeAi.model('gemma-3-1b-it'), prompt: prompt)

// Embeddings (EmbeddingGemma 300M)
ai.embed(embedder: flutterEdgeAi.embedder('embedding-gemma-300m'), document: ...)
```

See the [codelab](https://flutteredge.ai/codelabs/hybrid-ai-flutter-genkit/) for the full walkthrough.
