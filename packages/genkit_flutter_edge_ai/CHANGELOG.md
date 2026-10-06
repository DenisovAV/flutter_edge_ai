## 0.7.1
- **Breaking:** the `isThinking` option is `enableThinking`; require `flutter_edge_ai` ^2.1.0.
- Require `schemantic` ^0.2.3; the options schema is generated again (`schemantic_builder`).

## 0.7.0
- Require `flutter_edge_ai` 2.x.
- **Breaking:** remove the `genkit_flutter_gemma` name aliases; `dart fix --apply` still migrates.

## 0.6.2
- Renamed from `genkit_flutter_gemma` (`dart fix --apply` migrates); ids are now `flutter-edge-ai/…`.
- README: register `embeddingTokenizers:`, and pins for the 1.9.0 release.

## 0.6.1
- Relicensed from BSD-3-Clause to MIT, matching every other package.

## 0.6.0

- Upgrade to `genkit ^0.16.0` (from 0.15.1): `ActionType` is now a typed value (was `String`) and tool functions return `ToolResult` — `resolve()`/`list()` and the example's tools are updated accordingly.

## 0.5.0

- Upgrade to `genkit ^0.15.1` and `schemantic ^0.2.2` (from 0.14.1 / 0.2.0).
- Add `preferredBackend` / `preferredVisionBackend` / `preferredAudioBackend` to `FlutterGemmaModelOptions` (text decoder + vision/audio encoders).
- Honor Genkit 0.15 native top-level `request.toolChoice`; still falls back to the legacy config option.
- Advertise real capabilities (toolChoice, JSON) in resolved-model metadata; fixes empty `supports` at generate time.
- Structured JSON output via Genkit's instruction-injection fallback (`output: ['text','json']`, `constrained: false`).
- Add `trimContext()` context-window middleware — drops oldest turns to fit the on-device KV budget.

## 0.4.3

- Fix example: declare `ModelFileType.litertlm` for `.litertlm` models (desktop was declaring `.task`, routing them to MediaPipe). Adds a fileType-consistency test.

## 0.4.2

- Bump `genkit` to `^0.14.1` and `schemantic` to `^0.2.0`. No API or behavioral changes; tests green against the new versions.

## 0.4.1

- Move the package into the [flutter_gemma monorepo](https://github.com/DenisovAV/flutter_gemma) (`packages/genkit_flutter_gemma`); `repository`/`homepage` links updated accordingly. No API or behavioral changes.
- Bump `flutter_gemma` dependency constraint to `^1.0.1`.

## 0.4.0

- Bump flutter_gemma dependency to ^1.0.0 (modular package split: core + opt-in engine/backend packages)
- No changes to the public Genkit plugin API — `getActiveModel`/`getActiveEmbedder` signatures are unchanged, so all existing model/embedder config options keep working
- **App setup change**: flutter_gemma 1.0.0 makes inference engines and embedding backends opt-in. Consuming apps must now register them in `FlutterGemma.initialize()` and add the relevant packages (`flutter_gemma_litertlm`, `flutter_gemma_mediapipe`, `flutter_gemma_embeddings`). See the updated example and README.
- Update example app to register `LiteRtLmEngine`, `MediaPipeEngine`, and `LiteRtEmbeddingBackend`
- Drop the removed iOS-specific embedding tokenizer path (`iosPath`) — flutter_gemma 0.15.2+ unified embedding on a single LiteRT C API path

## 0.3.1

- Bump flutter_gemma dependency to ^0.15.1 (LiteRT-LM 0.11.0, MTP speculative decoding for Gemma 4, multi-image input, Android GPU fix, desktop storage path fix)
- Add `enableSpeculativeDecoding` config option for Gemma 4 E2B/E4B MTP toggle (`null` = model default, `true`/`false` = force on/off)

## 0.3.0

- Bump flutter_gemma dependency to ^0.14.2 (dart:ffi rewrite on desktop, ~5× faster cold start; fixes macOS `flutter test` install_name_tool failure)
- Add `maxFunctionBufferLength` config option for large tool-call argument payloads
- Update `example/macos/Podfile` post_install for flutter_gemma 0.14.2 framework bundling

## 0.2.2

- Bump flutter_gemma dependency to ^0.13.2
- Update README: document Gemma 4 and Phi-4 support, clarify thinking mode availability

## 0.2.1

- Bump flutter_gemma dependency to ^0.13.1 (LiteRT-LM 0.10.0, Gemma 4 thinking mode fix)

## 0.2.0

- **Breaking**: Upgrade flutter_gemma dependency to ^0.13.0
- **Breaking**: System messages are now passed natively via `createChat(systemInstruction:)` instead of being prepended to the first user message
- Add `systemInstruction` config option for explicit system-level instructions
- Support `ModelFileType.litertlm` for LiteRT-LM models (Gemma 4)
- Advertise `systemRole: true` in Genkit model metadata
- Throw on system-only requests (at least one user/model message required)
- Throw on system messages with non-text content parts

## 0.1.1

- Bump flutter_gemma dependency to ^0.12.8
- Add `toolChoice` config option ('auto', 'required', 'none') passed to model chat session
- Support `ParallelFunctionCallResponse` — multiple tool calls in a single model response
- Add `latencyMs` to ModelResponse for generation profiling
- Fix `FakeEmbeddingModel` compatibility with flutter_gemma 0.12.8 `taskType` parameter

## 0.1.0

- Initial release
- Genkit model provider wrapping flutter_gemma
- Text generation (blocking and streaming)
- Embeddings via FlutterGemmaEmbedder
- Multimodal input (images, audio)
- Function calling / tool use
- Thinking mode (DeepSeek-style reasoning)
- Configurable via `@Schema()`-annotated options
- Example app with Chat, Embeddings, Tools, Settings tabs
