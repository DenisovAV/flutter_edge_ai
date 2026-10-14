# Migration guide

## flutter_edge_ai 2.3.0: the embedding API, EmbeddingGemma 2, RAG 1.1

> **Upgrade every flutter_edge_ai package together** (`flutter pub upgrade`,
> not `flutter pub upgrade flutter_edge_ai`). Minimum versions with core
> 2.3.0: `flutter_edge_ai_litertlm` 1.13.0 · `flutter_edge_ai_embeddings`
> 2.3.0 · `flutter_edge_ai_onnx` 0.5.8 · `flutter_edge_ai_mediapipe` 1.2.2 ·
> `flutter_edge_ai_builtin_ai` 0.3.5 · `flutter_edge_ai_speech` 0.5.6 ·
> `flutter_edge_ai_agent` 0.2.9 · `flutter_edge_ai_rag` 1.1.0 ·
> `flutter_edge_ai_sqlite` 2.1.0 · `flutter_edge_ai_qdrant` 2.1.0. An older
> one fails to compile inside that package. `genkit_flutter_edge_ai` 0.9.0
> still compiles; 0.9.1 calls the new API and re-resolves a closed embedder.
> `flutter_edge_ai_diagnostics` and `genkit_hybrid` are unaffected.

```yaml
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_litertlm: ^1.13.0
  flutter_edge_ai_embeddings: ^2.3.0 # EmbeddingGemma 1 and other two-file models
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0     # or flutter_edge_ai_qdrant: ^2.1.0
```

### Embeddings

`EmbeddingModel` takes an `EmbeddingInput` and a required `TaskType`. The three
old methods still compile as deprecated forwarders and are removed in 2.5.0.

| Before (2.2) | After (2.3) |
|---|---|
| `generateEmbedding(t)` | `embed(EmbeddingInput.text(t), taskType: TaskType.retrievalQuery)`. The task is required; `TaskType.none` embeds the text with no prefix. |
| `generateEmbeddings(ts)` | `embedAll([for (final t in ts) EmbeddingInput.text(t)], taskType: …)`; it also takes a `cancelToken:`. |
| `await m.getDimension()` | `m.dimension` |
| a closed model threw `StateError` synchronously | `EmbedderClosedException`; every embedding error arrives as a failed future. Catch `EmbeddingException` for all of them. |
| inputs longer than the model's sequence length were truncated without a word (EmbeddingGemma 1 `.tflite`, ONNX static graphs, LiteRT.js on web, SigLIP) | `EmbeddingInputTooLongException(maxInputTokens, actualTokens)`. Chunk your text below `model.maxInputTokens` — task prefix, BOS and EOS included. |
| `TaskType { retrievalQuery, retrievalDocument }` | seven values appended: `none`, `questionAnswering`, `factChecking`, `codeRetrieval`, `classification`, `clustering`, `sentenceSimilarity`. Add the cases or a default branch to exhaustive switches; the first two keep their index. |
| `getActiveEmbedder({preferredBackend})` | adds `supportImage` and `supportAudio`: declare media at load. Media sent to a model that did not declare them throws. |
| `FlutterEdgeAiPlugin.createEmbeddingModel(modelPath:, tokenizerPath:)` | the explicit paths are gone. Install the files with `installEmbedder().modelFromFile(…)` (and `tokenizerFromFile(…)` unless it is a `.litertlm`), then call `getActiveEmbedder()`. |
| `EmbeddingModelSpec(tokenizerSource:)` was required | `tokenizerSource` is null for a `.litertlm` embedder; check `spec.isSelfContained`. `spec.files` has one entry then. |
| `installEmbedder()` without a tokenizer always threw | a `.litertlm` installs alone; a tokenizer for a `.litertlm` is an `ArgumentError` before any download, and a model no registered backend can run on this platform is an `UnsupportedError` before any download. |

New and additive: `EmbeddingInput.image`/`.audio`, `EmbeddingModality`,
`EncodedMediaFormat`, `sniffEncodedMediaFormat`, `EmbeddingModel.modalities`,
`maxInputTokens` and the `EmbeddingException` family
(`EmbeddingLoadException`, `EmbeddingEngineException`, …).

Test fakes and mocks: `EmbeddingModel` is an `abstract base class` now. A fake
is `final class FakeEmbedder extends EmbeddingModel` (add `with CloseNotifier`
from `package:flutter_edge_ai/engine.dart` for close listeners) implementing
`dimension`, `isClosed`, `embed`, `addCloseListener` and `close`.
`implements EmbeddingModel`, and therefore a mockito or mocktail mock of it, no
longer compiles, and `isClosed` is no longer defaulted.

### EmbeddingGemma 2

`flutter_edge_ai_litertlm` 1.13.0 runs EmbeddingGemma 2 text: one `.litertlm`
file that carries its own tokenizer, so it installs without
`tokenizerFrom…()` and needs no `flutter_edge_ai_embeddings`. Natively
(Android, iOS, macOS, Linux, Windows) on CPU, at most 1024 input tokens — keep
chunks at 512 or fewer. litertlm 1.13.1 adds images (the 440m and 740m
bundles), audio (the 740m), the web on WebGPU (text and images; audio and
combined inputs from 1.13.2) and Qualcomm NPUs (per-SoC bundles, Android and
Linux arm64); 1.13.2 adds the Intel Panther Lake NPU on Windows. See
the [litertlm README](https://pub.dev/packages/flutter_edge_ai_litertlm) for
the install snippet and its disk and memory cost.

### Web: copy the new `litert_embeddings.js`

The LiteRT.js embedding bundle changed its API. Copy `web/litert_embeddings.js`
from `flutter_edge_ai_litertlm` 1.13.0 (with the three files next to it) into
your app's `web/`. A stale copy fails `getActiveEmbedder()` with an
`EmbeddingLoadException` that names the file. Web EmbeddingGemma 1 now gets
the same task prefix and the same token ids as native for every `TaskType`.
From litertlm 1.13.1 an EmbeddingGemma 2 `.litertlm` embedder runs on web too,
on WebGPU: add `window.EmbeddingEngine = m.EmbeddingEngine;` to the
`@litert-lm/core` script in `web/index.html` (see the litertlm README's web
setup).

### Imports: `flutter_edge_ai.dart` for apps, `engine.dart` for engines

Core's internals moved under `lib/src`, which is private. The public
libraries are `flutter_edge_ai.dart` (apps), `engine.dart` (engine and
tokenizer packages; it re-exports the app library), `engine_io.dart`,
`engine_web.dart` and `genai.dart`.

| Before | After |
|---|---|
| `package:flutter_edge_ai/core/…`, `/mobile/…`, `/web/…`, `/desktop/…`, `/flutter_edge_ai_interface.dart`, `/model_file_manager_interface.dart` | `package:flutter_edge_ai/flutter_edge_ai.dart`; engine packages `package:flutter_edge_ai/engine.dart` |
| `EmbeddingTokenizerRegistry`, `SkillExecutorRegistry`, `ForwardResult`, `EmbeddingOutputContract`, `EmbeddingTokenizer`, `TokenizedInput`, `EmbeddingTokenizerFactory`, `meanPoolAndNormalize` from the app library | from `package:flutter_edge_ai/engine.dart` |
| `ModelThinkingFilter` through `package:flutter_edge_ai/core/extensions.dart` | the app library |
| `EmbeddingForwardPass`, `ForwardPassDescriptor`, `EmbeddingForwardPassFactory`, `CommonEmbeddingModel.create`, `EmbeddingBackendProvider.createModel` | `EmbeddingPass`, `EmbeddingPassInfo`, `EmbeddingPassDescriptor<C>`, `TokenEmbeddingPass` (if you tokenize in Dart) and `EmbeddingBackendProvider.describe()`, which returns `EmbeddingPassDescriptor(engineTag:, factory:, config:, activeBackend:)`. Core builds, hosts and closes the model. |
| `CommonEmbeddingModel.inputSequenceLength`, `.outputDimension` | `EmbeddingModel.maxInputTokens`, `.dimension` |
| `class MyBackend implements EmbeddingBackendProvider` | `extends EmbeddingBackendProvider` (an `abstract base class`) |
| `flutter_edge_ai_embeddings` re-exported core's seam types | it exports only `GemmaEmbeddingTokenizers`; import the seam types from `engine.dart`. A SigLIP input over 63 tokens throws instead of truncating. |
| onnx `OnnxEmbeddingForwardPass` | `OnnxEmbeddingPass` with `OnnxEmbeddingConfig`; it extends `TokenEmbeddingPass` |
| litertlm `WebEmbeddingModel` (`web_embedding_model.dart`) | removed: `FlutterEdgeAi.getActiveEmbedder()` |

### Removed deprecated members

| Removed | Use |
|---|---|
| `FlutterEdgeAi.initialize(enableWebCache:)` | `webStorageMode:` |
| `ModelFileManager.ensureModelReady(filename, url)` | `ensureModelReadyFromSpec(spec)` |
| `installModelFromAsset`, `installModelFromAssetWithProgress` | `FlutterEdgeAi.installModel(…).fromAsset(path)`, with `.withProgress(…)` |
| `setModelPath` | `FlutterEdgeAi.installModel(…).fromFile(path)` |
| `setLoraWeightsPath` | `FlutterEdgeAi.installModel(…).withLoraFromFile(path)` |
| `deleteLoraWeights` | install the model again without LoRA |
| `deleteCurrentModel` | `deleteModel(spec)` |
| `FunctionCallParser.isJsonStart`, `isJsonComplete` | `isFunctionCallStart`, `isFunctionCallComplete(buffer, modelType: …)` |
| `StopTokenFilter` | nothing: stop tokens have not reached the output since 0.14.0 |
| `FileSystemService.getTargetPath` | `getReadTargetPath` or `getWriteTargetPath` |
| `InferenceModelSpec.modelUrl`, `loraUrl` | `modelSource`, `loraSource` |
| `EmbeddingModelSpec.modelUrl`, `tokenizerUrl` | `modelSource`, `tokenizerSource` |
| `EmbeddingModelSpec.fromLegacyUrl` | `EmbeddingModelSpec(name: …, modelSource: ModelSource.network(url), tokenizerSource: ModelSource.network(tokenizerUrl))` |
| `MobileModelManager`/`WebModelManager.currentActiveModel`, `SmartDownloader.isHuggingFaceUrl` | these classes are internal now; read `FlutterEdgeAi.activeModelSpec` / `activeEmbedderSpec` |

`InferenceModelSpec.fromLegacyUrl` is deprecated and removed in 2.5.0. Build
the spec with the `ModelSource` that matches the URL:
`ModelSource.network(url)` for `http(s)://`, `ModelSource.asset(path)` for
`asset://` or a bare path, `ModelSource.bundled(name)` for `native://`,
`ModelSource.file(path)` for `file://`. The factory defaulted to
`modelType: ModelType.general`; pass that to keep its behaviour.

### RAG: `flutter_edge_ai_rag` 1.1, `flutter_edge_ai_sqlite` and `flutter_edge_ai_qdrant` 2.1

A location now binds one embedding profile **and** one document modality
(`VectorStoreSpec.documents`: text, image or audio).

| rag 1.0 | rag 1.1 |
|---|---|
| `open(spec:, activeEmbedderProfileId: id)`, profile bound on the first text operation | `open(spec:, embedder: FlutterEdgeAiActiveEmbedder(profileId: id))` — or `.forActiveModel(namespace:)` — resolves the profile (loading the model) and binds the location at once: install the embedder before `open()` |
| `open(spec:, embeddingProfile: p)` for precomputed vectors | `openVectors(spec:, profile: p)` |
| `index.addText(id:, content: c)` | `index.add(id:, document: EmbeddingInput.text(c))` |
| `index.searchText(query: q)` | `index.search(query: EmbeddingInput.text(q))` |
| `index.embeddingProfile` could be null | never null; `index.documents` names the modality |
| `RagEmbedder { profile, embedDocument(String), embedQuery(String) }` | `{ resolveProfile(), modalities, embedDocument(EmbeddingInput), embedQuery(EmbeddingInput, documentModality:) }`: wrap strings in `EmbeddingInput.text`, return `{EmbeddingModality.text}` from `modalities` |
| a filter on an undeclared field was ignored | `ArgumentError`: declare every filtered field in `VectorStoreSpec.filterSchema` |
| `VectorStoreRepository` (`implements`) with `readEmbeddingProfile`/`bindEmbeddingProfile` | `abstract base class` (`extends`) with `readBinding()`/`bind(VectorStoreBinding)`; the [rag README](https://pub.dev/packages/flutter_edge_ai_rag) describes how a store persists the binding |
| `EmbeddingProfile` ids could contain control characters | U+0000–U+001F are refused, and `EmbeddingProfile` can no longer be implemented |

`flutter_edge_ai_rag` re-exports `EmbeddingInput`, `EmbeddingModality`,
`TaskType` and the `EmbeddingException` family, and every error of a
`Future`-returning `RagIndex` or `FlutterEdgeAiRag` method arrives as a failed
future.

Stores written by sqlite/qdrant 2.0.x open unchanged in 2.1.0 as text
locations, and text locations move both ways. A location bound to images or
audio cannot be opened by sqlite/qdrant 2.0.x.

## flutter_edge_ai 2.2.0: sampling defaults come from the model

`createSession`, `openSession`, `createChat` and `openChat` no longer default to
`temperature: 0.8, randomSeed: 1, topK: 1`, which was greedy decoding for every
model. The four parameters are nullable, and an unset one comes from:

1. the sampler the model file ships — a native `.litertlm` bundle's, or an
   ONNX model's `genai_config.json`;
2. the defaults its family publishes, `SamplingParams.forModelType` (Gemma:
   `temperature: 1.0, topK: 64, topP: 0.95`);
3. `temperature: 0.8, topK: 40, topP: 0.95, randomSeed: 1`.

Output that was greedy is now sampled on LiteRT-LM and MediaPipe, except for
the families whose publishers decode greedily (Phi, Hammer). ONNX leaves unset
values to the model's config, on web too, where it used to decode greedily
whatever the config said; built-in AI keeps `temperature: 0.8, topK: 1`. Pass
`topK: 1` or `temperature: 0` to keep it greedy. Values you pass now also reach
ONNX and web `.litertlm`, which used to drop them, and a value no engine can
sample with (a negative temperature,
`topK` below 1, `topP` outside (0, 1]) throws an `ArgumentError`. `.litertlm`
keeps the sampler of an engine's first generation for every later conversation
(google-ai-edge/LiteRT-LM#2080): close and reload the model to change it.
`genkit_flutter_edge_ai` 0.8.1 and `flutter_edge_ai_agent` 0.2.8 pass unset
values through the same way. What each engine reads, and what it ignores, is
under [Sampling](https://flutteredge.ai/docs/getting-started#sampling).

Upgrade every `flutter_edge_ai_*` package together (`flutter pub upgrade`, not
`flutter pub upgrade flutter_edge_ai` alone): earlier engine releases override
the old signature and do not compile against core 2.2.0.

If you implement `InferenceModel` yourself, declare the parameters as
`double? temperature, int? randomSeed, int? topK, double? topP` and fill unset
ones with `SamplingParams.resolve`.

## flutter_edge_ai 2.1.0: `isThinking` is `enableThinking`

A rename with no `dart fix` rule, so the compiler finds every call site:

- `createSession`, `openSession`, `createChat` and `openChat` take
  `enableThinking:` instead of `isThinking:`.
- `ModelRuntimeDefaults.isThinking` is `thinkingDeclared` — what the model's
  manifest declares, which you pass on as
  `enableThinking: r.runtime.thinkingDeclared ?? false`.
- `genkit_flutter_edge_ai` 0.7: the `isThinking` model option is
  `enableThinking`.

Requires `flutter_edge_ai_litertlm` 1.9.0 or later, which sends the flag to the
runtime under the key chat templates read.

## flutter_edge_ai_litertlm 1.10.0: Android NPU is opt-in

Only apps that use `PreferredBackend.npu` on Android need to act. Qualcomm
licenses its QNN runtime for redistribution inside an application only, so the
package no longer ships it and every other Android app is about 83 MB smaller
on the device. An app that wants the Qualcomm NPU asks for it:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

- Put it in the pubspec of the app you build, or in the workspace root's
  pubspec if the app is a pub workspace member; pub reads `user_defines` from
  nowhere else, and the runtime log then says the stack is not enabled.
- The build hook downloads `com.qualcomm.qti:qnn-runtime` from Maven Central
  once per machine and caches it. Offline builds and CI without Maven access set
  `qualcomm_npu_maven_url` to a mirror or `qualcomm_npu_aar` to the AAR itself.
- Setting the flag accepts Qualcomm's AI Stack License. Qualcomm's notices are
  in the package's `NOTICES` and reach your app's licence page on their own.
- Requires `flutter_edge_ai` 2.1.1: core prepares the libraries the NPU
  dispatch loads, now from split APKs as well and off the main thread.

Without the flag nothing fails: `npu` falls back to GPU, then CPU, as on any
device without an NPU.

**Linux arm64 (`flutter_edge_ai_litertlm` 1.11.0).** The same flag also bundles
the Qualcomm NPU stack into Linux arm64 builds — Qualcomm Linux boards such as
the QCS6490, QCS8275 or QCS9075. The hook reads the QNN runtime out of
Qualcomm's public QAIRT SDK zip (about 32 MB of it, by range request);
`qualcomm_npu_qairt_zip` points it at a local copy. On the board the user must
be in group `fastrpc`. A Linux x64 build ignores the flag.

## Flutter Edge AI 1.x → 2.0: RAG leaves core

Flutter Edge AI 2.0 keeps inference, embeddings, speech, installation, and
model lifecycle in `flutter_edge_ai`, but moves RAG orchestration and all
vector-store contracts to `flutter_edge_ai_rag`. RAG is now instance-scoped and
can run with the active core embedder, a custom embedder, or precomputed vectors
without initializing core. The snippets below use the current RAG API
(`flutter_edge_ai_rag` 1.1, see the 2.3.0 section above).

Update dependencies:

```yaml
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0 # or flutter_edge_ai_qdrant: ^2.1.0
```

Remove `vectorStore:` and `filterSchema:` from `FlutterEdgeAi.initialize()`.
Register only AI runtimes there:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);
```

Then create and own the RAG index independently:

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'category', type: FilterFieldType.string),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder(
    profileId: 'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
        'retrieval-prefix-meanpool-l2-v1',
  ),
);

try {
  await index.add(id: 'doc-1', document: EmbeddingInput.text('Text to retrieve'));
  final hits = await index.search(
    query: EmbeddingInput.text('What should I retrieve?'),
  );
  await index.flush();
  print(hits);
} finally {
  await index.dispose();
}
```

The old and new calls map as follows:

| 1.x core RAG | `RagIndex` |
|---|---|
| `FlutterEdgeAi.rag.initialize(location)` | `FlutterEdgeAiRag(...).open(spec: VectorStoreSpec(location: ...), embedder: ...)` |
| `addDocument(...)` | `add(id: ..., document: EmbeddingInput.text(...))` |
| `addDocumentWithEmbedding(...)` | `addVector(...)` |
| `searchSimilar(query: ...)` | `search(query: EmbeddingInput.text(...))` |
| low-level vector search | `searchVector(embedding: ...)` |
| `removeDocument(id: ...)` | `remove(id: ...)` |
| `stats()` / `flush()` / `clear()` | same methods on the owned index |
| core/plugin teardown | `RagIndex.dispose()` before core/embedder teardown |

Also breaking in 2.0:

- `Filter`, `FilterSchema`, `RetrievalResult` and `VectorStoreRepository` now
  import from `package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart`.
- `ModelFileManager.setActiveModel` is removed; use `ensureModelReadyFromSpec`.
- The flutter_gemma-era name aliases (`FlutterGemma`, …) are gone;
  `dart fix --apply` still renames them.

### Embedding-profile migration

Every persistent location is now durably bound to an `EmbeddingProfile`. Its
ID must version the weights, tokenizer, pooling, normalization, and
document/query prefix contract; a path or mutable download URL is not a stable
identity. Use a different location after any of those inputs change.

For precomputed vectors, open a vector-only index with the profile of the
pipeline that produced them:

```dart
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(
    id: embeddingProfileId,
    dimension: 768,
  ),
);
```

A new store cannot infer which embedding space raw numbers belong to, so the
profile is required. If later searches embed text with the active core
embedder, open with `embedder: FlutterEdgeAiActiveEmbedder(profileId:
embeddingProfileId)` instead — `addVector` and `searchVector` work on that index
too. For independent text RAG, pass a custom `RagEmbedder` whose
`resolveProfile()` reports the same stable identity.

A nonempty 1.11 store has no profile metadata. The safest migration is a new,
profile-versioned location plus re-indexing. If you can independently attest
the exact old model and preprocessing, open once with
`VectorStoreSpec(…, allowLegacyProfileAdoption: true)` and the verified
`EmbeddingProfile` passed as `profile:` to `rag.openVectors`; the provider
checks the stored vector dimension before persisting the binding.

SQLite filter schemas are part of the physical `vec0` table. Adding or changing
a field requires a new schema-versioned location and re-indexing. Do not open a
database first without a schema and later expect `vec0` to alter it.

On Web, one location may have only one live SQLite index because the provider
holds an exclusive Web Lock. Keep one app-owned `RagIndex`, make its open future
single-flight, and dispose it before reopening the location. Dispose all RAG
indexes before `FlutterEdgeAi.dispose()` or before disposing a custom embedder.

## Historical: flutter_gemma → flutter_edge_ai (1.11.4)

The project is now **Flutter Edge AI**. Every package moved to a new name; the
code, the platforms and the on-device data are the same.

| Before | After |
|--------|-------|
| `flutter_gemma` | `flutter_edge_ai` 1.11.4 |
| `flutter_gemma_litertlm` | `flutter_edge_ai_litertlm` 1.8.6 |
| `flutter_gemma_mediapipe` | `flutter_edge_ai_mediapipe` 1.0.8 |
| `flutter_gemma_embeddings` | `flutter_edge_ai_embeddings` 2.2.1 |
| `flutter_gemma_rag_sqlite` | `flutter_edge_ai_sqlite` 1.4.0 |
| `flutter_gemma_rag_qdrant` | `flutter_edge_ai_qdrant` 1.3.2 |
| `flutter_gemma_speech` | `flutter_edge_ai_speech` 0.5.2 |
| `flutter_gemma_agent` | `flutter_edge_ai_agent` 0.2.6 |
| `flutter_gemma_builtin_ai` | `flutter_edge_ai_builtin_ai` 0.3.0 |
| `flutter_gemma_onnx` | `flutter_edge_ai_onnx` 0.5.1 |
| `flutter_gemma_diagnostics` | `flutter_edge_ai_diagnostics` 0.1.0 |
| `genkit_flutter_gemma` | `genkit_flutter_edge_ai` 0.6.2 |

The old `flutter_gemma*` packages stay on pub.dev as they are, so an app that
has not moved yet keeps working.

To move:

1. Replace each `flutter_gemma*` dependency in `pubspec.yaml` with its new name
   and the version from the table.
2. In your import lines replace `flutter_gemma` with `flutter_edge_ai`
   everywhere it appears — the package and the file name, e.g.
   `package:flutter_gemma/flutter_gemma.dart` →
   `package:flutter_edge_ai/flutter_edge_ai.dart`. Two packages also drop
   `rag_`: `flutter_gemma_rag_sqlite` → `flutter_edge_ai_sqlite` and
   `flutter_gemma_rag_qdrant` → `flutter_edge_ai_qdrant`.
3. Run `dart fix --apply` (Flutter 3.44 or newer). It renames `FlutterGemma`,
   `FlutterGemmaPlugin`, `FlutterGemmaDesktop`, `GemmaLogLevel`,
   `FlutterGemmaDiagnostics` and the genkit names to their new spellings. In 1.11.4
   they still compiled as deprecated aliases; `flutter_edge_ai` 2.0.0,
   `flutter_edge_ai_diagnostics` 0.2.0 and `genkit_flutter_edge_ai` 0.7.0 drop
   the aliases, and `dart fix --apply` renames the old names all the same.

If you installed the agent skills, run `dart run skills@ get --all` again
and delete the old `flutter-gemma-*` skill directories: they still teach the
old names.

What did not change in the 1.11.4 rename itself:

- Installed models, the model directory and the Web cache stay where they are,
  so nothing downloads again.
- Existing Qdrant and SQLite vector stores opened as before in 1.11.4. Moving
  onward to 2.0 requires the embedding-profile migration above.
- The Android package `dev.flutterberlin.*`, the platform channels and the
  macOS `post_install` snippet in your Podfile are unchanged.

Genkit: model and embedder ids are now `flutter-edge-ai/<name>`, and the
context-window middleware is registered as `flutter-edge-ai-context-window`.
Code that uses `flutterEdgeAi.model(...)` and `trimContext()` picks this up; a
hard-coded `'flutter-gemma/<name>'` string has to change. The old Dart names were
deprecated aliases in 0.6.2; 0.7.0 drops them, and `dart fix --apply` renames them.

Move every package at once: an app that keeps a `flutter_gemma_X` next to
`flutter_edge_ai_X` gets the same native libraries and Android classes twice,
and the build fails. An old satellite you did not move (say
`flutter_gemma_speech`) pulls the old engine back in the same way.

`flutter_edge_ai_sqlite` needs Flutter 3.47. An app on Flutter 3.44 that uses
the SQLite store upgrades Flutter first.

## Historical: flutter_gemma 0.x → 1.0

1.0 split the monolithic `flutter_gemma` plugin into a small **core** package
plus **opt-in** packages, so your app only ships the native weight it actually
uses. This is the **only breaking change**: you add the packages you need and one
`initialize(...)` call. The model/session/chat/embedding APIs stayed compatible
in that release; RAG later changed in 2.0 as documented above.

## TL;DR

1. Add the opt-in packages for the formats/features you use (see table below).
2. Call `await FlutterEdgeAi.initialize(inferenceEngines: [...], ...)` once in `main()`,
   passing the engines/backends from the packages you added.
3. Everything else stays the same.

## 1. pubspec.yaml

**Before (0.16.x):**
```yaml
dependencies:
  flutter_gemma: ^0.16.3
```

**Current equivalents (2.3):**
```yaml
dependencies:
  flutter_edge_ai: ^2.3.0                 # core — always required
  flutter_edge_ai_litertlm: ^1.13.0       # .litertlm + LiteRtEmbeddingBackend
  flutter_edge_ai_mediapipe: ^1.2.2       # .task / .bin
  flutter_edge_ai_embeddings: ^2.3.0      # tokenizer providers
  flutter_edge_ai_rag: ^1.1.0             # RAG orchestration + contracts
  flutter_edge_ai_qdrant: ^2.1.0          # native qdrant provider
  flutter_edge_ai_sqlite: ^2.1.0          # sqlite-vec provider; needs Flutter 3.47
```

Pick by what you actually used in 0.16.x:

| In 0.16.x you used… | Add now |
|---|---|
| `.litertlm` models (Gemma 4, Qwen3, FastVLM, any desktop) | `flutter_edge_ai_litertlm` |
| `.task` / `.bin` models (Gemma3n, Gemma 3, DeepSeek, Qwen 2.5, Phi-4, …) | `flutter_edge_ai_mediapipe` |
| `generateEmbedding()` / `installEmbedder()` | `flutter_edge_ai_litertlm` + `flutter_edge_ai_embeddings` (tokenizers, required since 1.9; see [Embedder decoupling](#embedder-decoupling-litertlm-150) below). `generateEmbedding` is `embed` since 2.3.0 |
| RAG on native | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| RAG on web | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` |

> Not sure which format your models are? Desktop runs `.litertlm`
> (`flutter_edge_ai_litertlm`), ONNX or built-in AI — no MediaPipe. On
> mobile/web check the file extension you install.
> You can add **both** engine packages and let the registry route each model by
> its file type.

> **New opt-in packages since 1.2/1.3** (not migration targets from the 0.16.x
> monolith — they add new capabilities): `flutter_edge_ai_agent` (on-device agent
> skills — SKILL.md + tool-calling loop), `flutter_edge_ai_builtin_ai` (OS
> system models — Gemini Nano on Android and Web, Apple Foundation Models on
> iOS/macOS, Windows AI Foundry on Windows; a thin adapter over
> `flutter_local_ai`, which owns the native layer), `flutter_edge_ai_onnx` (ONNX
> Runtime generation and embeddings) and `flutter_edge_ai_diagnostics` (memory
> a model costs, read from the OS).
> Add any of them only if you want that feature — see the README **Features** list.

## 2. main.dart — the one new call

**Before (0.16.x):** engines were bundled into core; `initialize()` was optional.
```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // (initialize was optional — only for HF token / retries)
  runApp(MyApp());
}
```

**After (1.0):** register the packages you added.
```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    // '' when the define is absent, and an empty token still sends a
    // bare `Authorization: Bearer` header — pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
  );

  runApp(MyApp());
}
```

Only list the AI runtimes you ship. RAG storage is registered independently on
`FlutterEdgeAiRag`, not on core.

## 3. Everything else is unchanged

These kept the same API through the 1.0 split — no edits needed for it (later
breaking changes, such as `isThinking` → `enableThinking` in 2.1.0, RAG
moving to `flutter_edge_ai_rag` in 2.0 and the embedding API of 2.3.0, are
covered above):

```dart
// install + run a model
await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(url, token: token).install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat  = await model.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello', isUser: true));
await for (final r in chat.generateChatResponseAsync()) { /* r is a ModelResponse */ }

// embeddings
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(modelUrl, token: token)
    .tokenizerFromNetwork(tokenizerUrl, token: token)
    .install();

// RAG: use the independently owned RagIndex shown in the 2.0 section above.
```

## What you'll see if you forget step 2

- Calling `getActiveModel()` with no matching `inferenceEngines` registered throws
  a `StateError` naming the model's `ModelFileType` and the engines that are
  registered — add the engine package for that file type.
- `FlutterEdgeAi.getActiveEmbedder()` with no `embeddingBackends` throws
  a clear "add an embedding backend package" error (e.g. `flutter_edge_ai_litertlm`'s
  `LiteRtEmbeddingBackend`).
- `FlutterEdgeAiRag.open()` with no matching provider throws and reports the
  registered provider IDs.

## Platform setup

Native setup moved to the package that owns it:

- **MediaPipe Gradle / Pod deps + the `@mediapipe/tasks-genai` web CDN** are now in
  `flutter_edge_ai_mediapipe` (bundled automatically on Android/iOS; add the CDN
  `<script>` for web — see the main README).
- **The `.litertlm` native library + the `@litert-lm/core` web CDN** are in
  `flutter_edge_ai_litertlm`.
- **The custom `sqlite3.wasm` (with `sqlite-vec`/`vec0` linked in)** ships as a web asset in `flutter_edge_ai_sqlite`.

The iOS/Android entitlements and manifest entries from the main README still
apply when you ship an inference engine. See the
[README platform setup](README.md#platform-setup) for the full list.

## Embedder decoupling (litertlm 1.5.0)

If you were on an earlier 1.x and imported `LiteRtEmbeddingBackend` from
`flutter_gemma_embeddings`, that class moved:

**Before:**
```dart
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
```

**After:**
```dart
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
```

`LiteRtEmbeddingBackend()` itself is unchanged — only the import path moved,
and there is no re-export shim, so it must be updated.

### Register a tokenizer (litertlm 1.8.0 / onnx 0.4.0)

An embedding backend no longer names a tokenizer. Which family a model needs
is a property of the MODEL, not of the engine that runs it — EmbeddingGemma is
SentencePiece whether LiteRT or ONNX Runtime executes its weights — so the app
supplies it, and the engine packages stopped depending on
`flutter_gemma_embeddings` because of it.

**Add the dependency** (it no longer arrives through the engine):
```yaml
dependencies:
  flutter_edge_ai_embeddings: ^2.3.0
```

**Add one line to `initialize`:**
```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],   // new
);
```

Omit it and `getActiveEmbedder()` fails with an `EmbeddingLoadException`
(its `cause` a `StateError`) naming this step. It
never falls back to a tokenizer of its own choosing: the wrong family produces
vectors that are quietly the wrong point in the embedding space, which no test
downstream can tell from a working model.

An app that never embeds anything passes neither list and can drop
`flutter_edge_ai_embeddings` entirely.

If your app used embeddings **without** also using `.litertlm` inference, add
`flutter_edge_ai_litertlm` to your `pubspec.yaml` — this also delivers the
shared native bundle (`libLiteRtLm`) your app was previously getting
transitively through `flutter_gemma_embeddings`'s old dependency on it.

## Troubleshooting

- **`dlopen` "library not found" after removing a package:** if you had both
  `flutter_edge_ai_litertlm` and `flutter_edge_ai_speech` and removed one, run
  `flutter clean` and delete `~/Library/Caches/flutter_gemma/native` (Windows:
  `%LOCALAPPDATA%\flutter_gemma\native`), then `flutter pub get`. They share one
  native library (`flutter_edge_ai_embeddings` 2.x has no native code); see
  those packages' READMEs.
