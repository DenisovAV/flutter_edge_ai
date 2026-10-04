# AGENTS.md

This file provides guidance to coding agents working with this package.

## Commands

```bash
# Get dependencies
flutter pub get

# Run all tests
flutter test

# Run a single test file
flutter test test/converters/response_converter_test.dart

# Static analysis
dart analyze

# Dry-run publish check
dart pub publish --dry-run

# Format code
dart format .
```

## Architecture

This is a **Genkit Dart plugin** that bridges [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) (on-device AI inference) into the [Genkit](https://pub.dev/packages/genkit) framework.

### Plugin structure

`GenkitFlutterEdgeAiPlugin` implements Genkit's `GenkitPlugin` interface with `list()` (advertises models/embedders) and `resolve()` (lazily creates and caches actions). Models are registered under the `flutter-edge-ai/` prefix.

### Key abstractions

- **`FlutterEdgeAiRuntime`** — abstracts flutter_edge_ai's static API (`FlutterEdgeAi.getActiveModel`, `FlutterEdgeAi.getActiveEmbedder`). Production uses `DefaultFlutterEdgeAiRuntime`; tests use `FakeRuntime` from `test/src/fake_runtime.dart`.
- **Model action** (`flutter_edge_ai_model.dart`) — implements a serialized queue via future-chain lock, caches `InferenceModel` across calls, and delegates to blocking/streaming generation paths.
- **Embedder action** (`flutter_edge_ai_embedder.dart`) — caches `EmbeddingModel` with backend invalidation.

### Converter layer (`lib/src/converters/`)

Three converters handle the Genkit ↔ flutter_edge_ai type boundary:
- **`request_converter.dart`** — Genkit `Message` → `gemma.Message`. System role is prepended to first user message (flutter_edge_ai has no system role). Media resolution supports `data:` URIs, `file://`, absolute paths, and HTTP URLs.
- **`response_converter.dart`** — `gemma.ModelResponse` → Genkit `ModelResponse`/`ModelResponseChunk`. Handles text, function calls (single and parallel), and reasoning/thinking parts.
- **`tool_converter.dart`** — Genkit `ToolDefinition` → `gemma.Tool`.

### Config options

`FlutterEdgeAiModelOptions` is defined via `@Schema()` annotation in `flutter_edge_ai_options.dart`. Generated via `schemantic` + `build_runner`.

**`build_runner` note**: Use `dart pub global run build_runner build --delete-conflicting-outputs` (run `dart pub global activate build_runner` once first). The globally activated build_runner runs as an AOT executable which avoids any native_assets bundling issues.

### Testing pattern

All tests use `FakeRuntime` + `FakeInferenceModel` + `FakeInferenceChat` from `test/src/fake_runtime.dart`. The fakes must stay in sync with flutter_edge_ai's `InferenceModel`/`InferenceChat`/`EmbeddingModel` method signatures when bumping the dependency.

## Lint rules

Uses `flutter_lints` with `prefer_const_constructors`, `prefer_const_declarations`, `avoid_print`, `prefer_single_quotes` enabled. The `example/test/widget_test.dart` has a pre-existing error (`MyApp` not found) — ignore it.
