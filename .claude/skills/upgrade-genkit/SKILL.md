---
name: upgrade-genkit
description: Realign the genkit_flutter_edge_ai / genkit_hybrid packages when flutter_edge_ai's core API changes — discover changes, fix compilation, support new features, update fakes/tests, bump version. Monorepo-aware.
user_invocable: true
---

# Upgrade Genkit packages to the current flutter_edge_ai API

The Genkit integration packages (`packages/genkit_flutter_edge_ai`, `packages/genkit_hybrid`)
wrap flutter_edge_ai's public API. When that API changes, they must be realigned or
they break. In the **monorepo** they consume flutter_edge_ai as an in-workspace
path dependency, so a core change can break them in the same commit — run this
whenever a PR changes the public `InferenceModel` / `InferenceChat` /
`EmbeddingModel` / `Message` / `ModelResponse` / enum surface.

Follow these 5 phases sequentially. Ask the user before deciding which new
features to support (Phase 3).

> Paths below are relative to the repo root. Core package =
> `packages/flutter_edge_ai`; genkit package = `packages/genkit_flutter_edge_ai`
> (mirror for `genkit_hybrid`). `REPO_ROOT` = monorepo root,
> `PKG_DIR=packages/genkit_flutter_edge_ai`, `EXAMPLE_DIR=$PKG_DIR/example`.

## Phase 1: Reconnaissance

1. Identify what changed in the core public API. In the monorepo flutter_edge_ai
   is a path dep (not pub), so don't rely on `dart pub outdated` — instead read
   the diff / CHANGELOG of `packages/flutter_edge_ai`:
   - `git log --oneline -- packages/flutter_edge_ai/lib/flutter_edge_ai_interface.dart packages/flutter_edge_ai/lib/core`
   - `packages/flutter_edge_ai/CHANGELOG.md` (top entry)
2. Summarize for the user:
   - **Breaking changes** (removed/renamed APIs, changed signatures)
   - **New APIs** (new parameters, methods, enums, classes)
   - **Bug fixes** / **Deprecations**
3. `melos bootstrap` (or `dart pub get` in `PKG_DIR` + `EXAMPLE_DIR`).

## Phase 2: Fix Compilation

1. `cd packages/genkit_flutter_edge_ai && dart analyze` (repeat for `genkit_hybrid`).
2. Fix all compilation errors. Files that depend on flutter_edge_ai's API:
   - [ ] `lib/src/flutter_edge_ai_runtime.dart` — `FlutterEdgeAi.getActiveModel()`, `getActiveEmbedder()` signatures
   - [ ] `lib/src/flutter_edge_ai_model.dart` — `InferenceModel.createChat()` signature, `ModelResponse` pattern matching, `InferenceChat` methods
   - [ ] `lib/src/flutter_edge_ai_embedder.dart` — `EmbeddingModel.generateEmbeddings()`, `PreferredBackend` enum
   - [ ] `lib/src/converters/request_converter.dart` — `Message` constructors (`.withImage`, `.withAudio`, `.toolCall`, `.toolResponse`)
   - [ ] `lib/src/converters/response_converter.dart` — `ModelResponse` subtypes (`TextResponse`, `FunctionCallResponse`, `ParallelFunctionCallResponse`, `ThinkingResponse`)
   - [ ] `lib/src/converters/tool_converter.dart` — `Tool` constructor
   - [ ] `lib/src/flutter_edge_ai_plugin.dart` — `ModelType`, `ModelFileType` enums
   - [ ] `test/src/fake_runtime.dart` — `FakeInferenceModel`, `FakeInferenceChat`, `FakeEmbeddingModel` **must** match upstream abstract-class signatures (see genkit `AGENTS.md`)
3. Repeat `dart analyze` until clean (0 issues).

## Phase 3: Support New Features

Based on Phase 1, decide with the user which new APIs to support. Typical integration points:

### New parameter in `createChat()` / `createSession()`
1. Add field to `$FlutterEdgeAiModelOptions` in `lib/src/flutter_edge_ai_options.dart`
2. **Manually** update `lib/src/flutter_edge_ai_options.g.dart` (constructor param, field with `@override`, `fromJson`, `toJson`, `jsonSchema()` entry)
3. Extract from config + pass in `lib/src/flutter_edge_ai_model.dart` (`_executeGeneration`)
4. Update `FakeInferenceModel.createChat()` in `test/src/fake_runtime.dart` (add param, store in `last*` field for assertions)

### New enum value (e.g. `ModelFileType`)
- Update comments in `lib/src/flutter_edge_ai_plugin.dart` (`FlutterEdgeAiModelConfig.fileType`)

### New method on `InferenceChat` / `InferenceModel`
- Add override in `FakeInferenceChat` / `FakeInferenceModel` in `test/src/fake_runtime.dart`

### Changed model capabilities
- Update `supports` map in `lib/src/flutter_edge_ai_plugin.dart` (`list()` method)

### Changed message handling
- Update converters in `lib/src/converters/`; update `extractSystemInstruction()` if system-message handling changed

**IMPORTANT:** `*.g.dart` here is **manually maintained** (build_runner not used by default). Always hand-update it when changing the schema.

## Phase 4: Tests and Review

1. Update existing tests that verify changed behavior.
2. Add tests for each new feature from Phase 3.
3. `flutter test` (in `PKG_DIR`) — all must pass.
4. Run `/review-pr` for comprehensive review; fix what it surfaces.

## Phase 5: Finalize

1. **Bump version** in `PKG_DIR/pubspec.yaml` (minor for breaking behavior, patch for fixes/non-breaking additions).
2. **Update `PKG_DIR/CHANGELOG.md`** (new section at top: breaking `**Breaking**:` / new features / fixes).
3. **Update `PKG_DIR/README.md`** (options table, known limitations, quick-start if usage changed).
4. Verify: `dart analyze && flutter test && dart pub publish --dry-run` (all clean).
5. The release itself goes through the **`release` skill** (genkit packages release in lockstep with the monorepo) — do not publish standalone.
