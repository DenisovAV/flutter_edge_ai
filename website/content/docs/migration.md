---
title: Migration
description: Upgrade to Flutter Edge AI 2.5 (openModel, createModel deprecated, members deprecated for 2.5 removed), flutter_edge_ai_litertlm 1.16 (openModel) and 1.15 (npu on a generic bundle runs on the GPU, opt-in Google Tensor NPU), flutter_edge_ai_agent 0.4 (notifications are opt-in), Flutter Edge AI 2.4 (backends follow the .litertlm file, Gemma 4 audio after the text, agent 0.3), 2.3 (the embedding API, EmbeddingGemma 2, RAG 1.1), 2.2 (sampling defaults from the model), 2.1 (enableThinking, opt-in Qualcomm NPU) and 2.0 (RAG moves to flutter_edge_ai_rag), move from flutter_gemma to flutter_edge_ai, and from the 0.16.x monolith to the modular packages.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

## flutter_edge_ai 2.5.0: several open models, removed and deprecated members, embedding providers

### Removed members

| Removed | Use |
|---|---|
| `EmbeddingModel.generateEmbedding(t)` | `embed(EmbeddingInput.text(t), taskType: TaskType.retrievalQuery)` |
| `EmbeddingModel.generateEmbeddings(ts)` | `embedAll([for (final t in ts) EmbeddingInput.text(t)], taskType: TaskType.retrievalQuery)` |
| `EmbeddingModel.getDimension()` | `dimension` |
| `InferenceModelSpec.fromLegacyUrl(name:, modelUrl:, loraUrl:)` | `InferenceModelSpec(name: …, modelSource: …, loraSource: …, modelType: …)` |

The removed embedding methods embedded as `TaskType.retrievalQuery` unless given
a `taskType:`; pass the same task to keep their vectors.
`genkit_flutter_edge_ai` 0.9.0 and older call `generateEmbeddings` and do not
compile against 2.5.0: upgrade it to 0.9.1 or later. For `fromLegacyUrl`, use
the `ModelSource` that matches the URL: `ModelSource.network(url)` for
`http(s)://`, `ModelSource.asset(path)` for `asset://` or a bare path,
`ModelSource.bundled(name)` for `native://`, `ModelSource.file(path)` for
`file://`. The factory defaulted to `modelType: ModelType.general`.

### `FlutterEdgeAiPlugin.createModel` is deprecated

`FlutterEdgeAiPlugin.instance.createModel(modelType:, fileType:, …)` is
deprecated and removed in 2.6.0. On Android, iOS and desktop it ignored
`modelType` and `fileType` and returned the active model, which is what
`FlutterEdgeAi.getActiveModel()` returns. The two ways to get a model are on
`FlutterEdgeAi`:

| Before | After |
|---|---|
| `FlutterEdgeAiPlugin.instance.createModel(modelType: …, maxTokens: …)` | `FlutterEdgeAi.getActiveModel(maxTokens: …)` |
| several models through `src/` imports | `FlutterEdgeAi.openModel(spec, …)` on a spec from `install(activate: false)`, with `LiteRtLmEngine` (`flutter_edge_ai_litertlm` 1.16.0) |

### Embedding providers: `.gguf` without a tokenizer, accelerators

Embedding specs accept `.gguf` without a separate tokenizer. For an opaque URL,
use `modelFromNetwork(url, filename: 'model.gguf')`. Old `.gguf` plus tokenizer
specs are now refused during installation and stored-identity restoration; no
published backend produced those pairs. Other model/tokenizer pairs and existing
`.litertlm` identity schemas keep their behavior. No GGUF embedding backend ships
yet; a separate engine package is required to execute these files.

Follow-on: `flutter_edge_ai_llama` 0.0.3 adds the opt-in
`LlamaEmbeddingBackend` for native EmbeddingGemma 2 GGUF text embeddings using
the core 2.5.0 embedding SPI and llamadart 0.15.1. Register it through
`FlutterEdgeAi.initialize(embeddingBackends:)` and install the GGUF alone.
Keep a separate RAG vector profile from LiteRT; matching dimensions are not
vector compatibility. `flutter_edge_ai_embeddings` remains tokenizer-only.
The statement above describes availability at the core 2.5.0 release.

Engine authors declare explicit accelerator capabilities through
`EmbeddingBackendProvider.honouredBackends(spec)`; core computes cache identity.
Automatic requests reuse only a non-NPU embedder for the same installed model
and media; explicit NPU requests always retain a separate key. Repeated explicit
CPU/GPU requests reuse their originating model, including a fallback, until a
rebuild is needed or the model is closed. A fallback warning is printed once per
new load, including reporting-provider NPU fallbacks. GPU-capable
providers must report the loaded accelerator in `EmbeddingPassInfo.activeBackend`.
Existing providers using the default capability set retain descriptor fallback,
including the fixed WebGPU-only LiteRT-LM path.

`maxInputTokens` is the effective limit accepted by the loaded pass, including
context and single-pass batch limits, task prefixes and special tokens. A null
limit means unknown, not unlimited. GGUF's configured 1024-token context and
micro-batch can be smaller than a model file's theoretical limit; advertising
that larger limit would let RAG choose chunks the runtime cannot execute.
Existing providers' numeric limits do not change. Inputs are never truncated.

## flutter_edge_ai 2.4.1 / flutter_edge_ai_litertlm 1.15.0: `npu` on a generic bundle runs on the GPU

```
dependencies:
  flutter_edge_ai: ^2.4.1
  flutter_edge_ai_litertlm: ^1.15.0   # requires flutter_edge_ai 2.4.1
```

- `PreferredBackend.npu` on a bundle compiled for no NPU (a generic one) is
  never tried on the NPU: where the NPU was reachable, LiteRT ran such a
  bundle on the CPU while `activeBackend` reported `npu`. It runs on the GPU,
  then the CPU, with a notice; with `LiteRtLmEngine(backendFallback: false)`
  it is refused with a `LiteRtLmBundleException` (`wrongBackend`). To run on
  the NPU, install the bundle compiled for it.
- Google Tensor G5/G6 bundles run on the NPU of a Pixel with that Tensor
  generation and Android 16 or later (not a `BP2A` build). It is opt-in, as
  Qualcomm's is:
  `google_tensor_npu: true` in the same `user_defines` block. Without it such
  a bundle fails with a `BackendInitException` that says how to enable it.

See [where a model runs](/docs/litertlm#where-a-model-runs).

## `flutter_edge_ai_agent` 0.4.0: `schedule_notification` is opt-in

```
dependencies:
  flutter_edge_ai_agent: ^0.4.0
```

`NativeIntentExecutor()` no longer schedules notifications: the intent returns
an error until the app passes `NotificationIntentSettings`. Before, it
scheduled whether or not the app had called `initialize`, and without it the
app crashed: on macOS when the intent scheduled, on Android when the reminder
fired with no small icon. An app that uses the intent:

1. calls `FlutterLocalNotificationsPlugin().initialize(...)` once at startup,
   with its own callbacks, its default icon and settings for every platform it
   builds for (`initialize` throws without them) — the agent never does;
2. passes `NativeIntentExecutor(notifications: const NotificationIntentSettings())`;
3. on Android, declares `SCHEDULE_EXACT_ALARM` and, on Android 14 and newer,
   asks for it with `requestExactAlarmsPermission()`, or passes
   `androidExactAlarm: false` for an inexact reminder.

The intent checks the permissions and refuses instead of asking for them, and
it no longer loads the time zone database, which reset the app's `tz.local`
to UTC. A `schedule_notification` entry in `handlers:` still replaces the
built-in intent, but not together with `notifications:`.

Every `schedule_notification` call, an app's own handler included, is now
refused before it runs when its date is partial (a `day` without `year` and
`month`) or does not exist (February 31). Without a date, a time that has
passed today moves to tomorrow at the same wall-clock time, across a clock
change too. The mail and SMS intents write a space as `%20` instead of `+`.
See [Agent → Setup](/docs/agent#setup).

## flutter_edge_ai 2.4.0 / flutter_edge_ai_litertlm 1.14.0: backends follow the model file

> Upgrade these together: `flutter_edge_ai` 2.4.0, `flutter_edge_ai_litertlm`
> 1.14.0, `flutter_edge_ai_agent` 0.3.0 and `genkit_flutter_edge_ai` 0.10.0.
> litertlm 1.13.x and genkit 0.9.x compile against core 2.4.0 but ignore
> `multimodalOrder`, `activeVisionBackend` / `activeAudioBackend` and tool call
> ids. The other packages are unchanged.

```
dependencies:
  flutter_edge_ai: ^2.4.0
  flutter_edge_ai_litertlm: ^1.14.0
  flutter_edge_ai_agent: ^0.3.0       # if you use it
  genkit_flutter_edge_ai: ^0.10.0     # if you use it
```

### `implements InferenceModel`

A class that `implements InferenceModel` declares three new members:
`createDecider` (fail it with `DeciderUnsupportedException`), and the getters
`activeVisionBackend` and `activeAudioBackend` (null when the model has no such
encoder or the engine does not say). A class that `extends InferenceModel`
inherits all three.

### Where a `.litertlm` runs

Before it creates an engine, litertlm 1.14.0 reads the bundle's header and
decides from it
([where a model runs](/docs/litertlm#where-a-model-runs)).
What can change for an existing app:

- A bundle compiled for an NPU (e.g. `…_qualcomm_sm8750.litertlm`) with no
  `preferredBackend` now runs on the NPU. With `PreferredBackend.gpu` or `cpu`
  it is refused with a `LiteRtLmBundleException` (`wrongBackend`); on a device
  whose NPU cannot be reached it fails with a `BackendInitException` that names
  the cause. It is never tried on the GPU or the CPU. A generic bundle with
  `npu` still falls back to GPU, then CPU.
- An encoder you leave unset runs where its section says, reported in
  `activeVisionBackend` / `activeAudioBackend`: Gemma 4 vision and audio on the
  CPU, Gemma 3n vision on the GPU and its audio on the CPU.
- `preferredAudioBackend: PreferredBackend.gpu` on Gemma 4 or Gemma 3n is
  refused with a `LiteRtLmBundleException` (`wrongBackend`): their audio
  encoders declare `backend_constraint` cpu. Remove it.
- `preferredVisionBackend: PreferredBackend.cpu` on Gemma 3n is refused the
  same way: its vision encoder declares gpu only. Remove it.
- An encoder backend left unset and an explicit `PreferredBackend.cpu` are
  different requests now: switching between them reloads the model.
- A download that stopped early is refused before any engine
  (`LiteRtLmBundleException`, `incomplete`): install the file again.

New and optional: `LiteRtLmEngine(backendFallback: false)` makes one attempt
and fails with LiteRT-LM's own reason, and `readLiteRtLmBundleInfo(path)` shows
what the engine reads.

### Gemma 4 gets its audio after the text

litertlm 1.14.0 sends a Gemma 4 message's images, then its text, then its audio
(`MultimodalOrder.imagesTextAudio`, the order of the model card); every other
model keeps images, audio, text. Pass
`getActiveModel(multimodalOrder: MultimodalOrder.imagesAudioText)` to keep the
old order.

### `flutter_edge_ai_agent` 0.3.0

`EmptyAnswerRetryEvent` is a new `AgentEvent`, so an exhaustive `switch` over
`AgentEvent` needs a case for it: the loop emits it when it asks again after an
empty answer that followed `loadSkill` (`emptyAfterSkillRetries`, default 1).
A turn that stays empty ends with `EmptyAnswerEvent`, a `DoneEvent`.

### `genkit_flutter_edge_ai` 0.10.0

Requires `flutter_edge_ai` ^2.4.0. Tool `ref`s travel as call ids both ways: a
tool request's `ref` is the call's id (`call_0`, `call_1`, … when it has none),
and a tool response's `ref` becomes the `toolCallId` of the message it is sent
back as.

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

```
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_litertlm: ^1.13.0
  flutter_edge_ai_embeddings: ^2.3.0 # EmbeddingGemma 1 and other two-file models
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0     # or flutter_edge_ai_qdrant: ^2.1.0
```

### Embeddings

`EmbeddingModel` takes an `EmbeddingInput` and a required `TaskType`. The three
old methods stayed as deprecated forwarders until 2.5.0 removed them.

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
| `installEmbedder()` without a tokenizer always threw | a `.litertlm` installs alone; a tokenizer for a `.litertlm` is an `ArgumentError` before any download, and, once an embedding backend is registered, a model none of them can run on this platform is an `UnsupportedError` before any download (with none registered the install goes ahead). |

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
`tokenizerFrom…()` and needs no `flutter_edge_ai_embeddings`. Android, iOS,
macOS, Linux and Windows, CPU, at most 1024 input tokens — keep chunks at 512
or fewer. Images, the Web (text and images) and audio arrive in
litertlm 1.13.1, audio and combined inputs on the Web in 1.13.2. See
[Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2) for the install
snippet and its disk and memory cost.

### Web: copy the new `litert_embeddings.js`

The LiteRT.js embedding bundle changed its API. Copy `web/litert_embeddings.js`
from `flutter_edge_ai_litertlm` 1.13.0 (with the three files next to it) into
your app's `web/`. A stale copy fails `getActiveEmbedder()` with an
`EmbeddingLoadException` that names the file. Web EmbeddingGemma 1 now gets
the same task prefix and the same token ids as native for every `TaskType`. In
1.13.0 a `.litertlm` embedder was refused on web at `install()`; since 1.13.1 it
runs on WebGPU, with `window.EmbeddingEngine = m.EmbeddingEngine;` in
`web/index.html` (see [Installation → Web](/docs/installation#web)).

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
| `class MyBackend implements EmbeddingBackendProvider` | `final class MyBackend extends EmbeddingBackendProvider` (an `abstract base class`) |
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

`InferenceModelSpec.fromLegacyUrl` was deprecated here and removed in 2.5.0. Build
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
under [Sampling](/docs/getting-started#sampling).

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
- `genkit_flutter_edge_ai` 0.7.1: the `isThinking` model option is
  `enableThinking`.

Requires `flutter_edge_ai_litertlm` 1.9.0 or later, which sends the flag to the
runtime under the key chat templates read.

## flutter_edge_ai_litertlm 1.10.0: Android NPU is opt-in

Only apps that use `PreferredBackend.npu` on Android need to act. Qualcomm
licenses its QNN runtime for redistribution inside an application only, so the
package no longer ships it and every other Android app is about 83 MB smaller
on the device. An app that wants the Qualcomm NPU asks for it in its
`pubspec.yaml` (the workspace root's, if the app is a pub workspace member):

```
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

The build hook downloads `com.qualcomm.qti:qnn-runtime` from Maven Central once
per machine and caches it; offline builds set `qualcomm_npu_maven_url` to a
mirror or `qualcomm_npu_aar` to the AAR itself. Setting the flag accepts
Qualcomm's AI Stack License. It needs `flutter_edge_ai` 2.1.1. Without the flag
a generic bundle still loads: `npu` falls back to GPU, then CPU. A bundle
compiled for an NPU cannot run anywhere else, so from litertlm 1.14.0 its load
fails instead, with a `BackendInitException` whose one attempt says the stack
is not enabled. See [LiteRT-LM](/docs/litertlm).

**Linux arm64 (`flutter_edge_ai_litertlm` 1.11.0).** The same flag also bundles
the Qualcomm NPU stack into Linux arm64 builds — Qualcomm Linux boards such as
the QCS6490, QCS8275 or QCS9075. The hook reads the QNN runtime out of
Qualcomm's public QAIRT SDK zip (about 32 MB of it, by range request);
`qualcomm_npu_qairt_zip` points it at a local copy. On the board the user must
be in group `fastrpc`. A Linux x64 build ignores the flag.

## Flutter Edge AI 1.x → 2.0: RAG leaves core

Flutter Edge AI 2.0 keeps inference, embeddings, speech, installation, and
model lifecycle in `flutter_edge_ai`, but moves RAG orchestration and all
vector-store contracts to `flutter_edge_ai_rag`. RAG is instance-scoped and can
use the active core embedder, a custom embedder, or precomputed vectors without
initializing core. The snippets below use the current RAG API
(`flutter_edge_ai_rag` 1.1, see the 2.3.0 section above).

```
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0 # or flutter_edge_ai_qdrant: ^2.1.0
```

Also breaking in 2.0:

- `Filter`, `FilterSchema`, `RetrievalResult`, `VectorStoreRepository` and the
  other RAG types now import from `package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart`,
  not from core.
- `ModelFileManager.setActiveModel` is removed — use `ensureModelReadyFromSpec`.
- The deprecated `flutter_gemma` name aliases (`FlutterGemma`, `GemmaLogLevel`, …)
  are removed. `dart fix --apply` still renames them.

Remove `vectorStore:` and `filterSchema:` from `FlutterEdgeAi.initialize()`.
Register only AI runtimes there, then create and own RAG independently:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
);

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

### Embedding profiles and persistent data

Every persistent location is durably bound to an `EmbeddingProfile`. Its ID
must version the weights, tokenizer, pooling, normalization, and document/query
prefix contract. For precomputed vectors, open a vector-only index with
`openVectors(spec:, profile:)`; if later text searches borrow the active core
embedder, open with `embedder: FlutterEdgeAiActiveEmbedder(profileId:)` instead
— `addVector` works on that index too. Independent text RAG passes a custom
`RagEmbedder` whose `resolveProfile()` reports that stable identity.

A nonempty 1.11 store has no profile metadata. Prefer a new, profile-versioned
location and re-index. If you can independently attest the old model and
preprocessing, open once with `allowLegacyProfileAdoption: true` on the
`VectorStoreSpec` and the verified profile passed to `openVectors(profile:)`;
the provider checks the stored dimension before binding it.

SQLite filter fields are physical `vec0` columns, so a schema change needs a
new schema-versioned location and re-index. On Web, keep one app-owned index per
location because SQLite holds an exclusive Web Lock. Dispose RAG indexes before
`FlutterEdgeAi.dispose()` or before disposing a custom embedder.

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
2. In your import lines, replace `flutter_gemma_rag_` with `flutter_edge_ai_`
   first (`flutter_gemma_rag_sqlite` → `flutter_edge_ai_sqlite`,
   `flutter_gemma_rag_qdrant` → `flutter_edge_ai_qdrant`), then `flutter_gemma`
   with `flutter_edge_ai` everywhere — in the package name and in the file name:
   `package:flutter_gemma/flutter_gemma.dart` becomes
   `package:flutter_edge_ai/flutter_edge_ai.dart`. A project-wide search and
   replace does it.
3. Run `dart fix --apply` (Flutter 3.44 or newer). It renames `FlutterGemma`,
   `FlutterGemmaPlugin`, `FlutterGemmaDesktop`, `GemmaLogLevel`,
   `FlutterGemmaDiagnostics` and the genkit names to their new spellings. In 1.11.4
   they still compiled as deprecated aliases; `flutter_edge_ai` 2.0.0,
   `flutter_edge_ai_diagnostics` 0.2.0 and `genkit_flutter_edge_ai` 0.7.0 drop
   the aliases, and `dart fix --apply` renames the old names all the same.

If you installed the agent skills, run `dart run skills@ get --all` again
and delete the old `flutter-gemma-*` skill directories: they still teach the
old names.

What does not change:

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
`initialize(...)` call. Model/session/chat/embedding APIs stayed compatible in
that release; RAG later changed in 2.0 as documented above.

## TL;DR

1. Add the opt-in packages for the formats/features you use (see table below).
2. Call `await FlutterEdgeAi.initialize(inferenceEngines: [...], ...)` once in `main()`, passing the engines/backends from the packages you added.
3. Then apply the 2.0–2.4 sections above: RAG moved to `flutter_edge_ai_rag`
   (2.0), `isThinking` became `enableThinking` (2.1), sampling defaults come
   from the model (2.2), the embedding API changed (2.3), backends follow the
   `.litertlm` file (2.4, litertlm 1.14 and 1.15), and, if you use the agent,
   `schedule_notification` is opt-in (`flutter_edge_ai_agent` 0.4).

## 1. pubspec.yaml

**Before (0.16.x):**

```
dependencies:
  flutter_gemma: ^0.16.3
```

**After (current 2.5 set):**

```
dependencies:
  flutter_edge_ai: ^2.5.4                 # core — always required
  flutter_edge_ai_litertlm: ^1.19.0       # add if you run .litertlm models (also provides LiteRtEmbeddingBackend)
  flutter_edge_ai_mediapipe: ^1.2.4       # add if you run .task / .bin models
  flutter_edge_ai_embeddings: ^2.3.2      # add if you compute embeddings with a tokenizer file (needs a backend, see above)
  flutter_edge_ai_rag: ^1.1.2             # add for on-device RAG (RagIndex) + one store below
  flutter_edge_ai_qdrant: ^2.1.1          # native on-device RAG store (qdrant)
  flutter_edge_ai_sqlite: ^2.1.1          # RAG store (sqlite-vec; all platforms incl. web) — needs Flutter 3.47
```

Pick by what you actually used in 0.16.x:

| In 0.16.x you used… | Add |
|---|---|
| `.litertlm` models (any desktop model included) | `flutter_edge_ai_litertlm` |
| `.task` / `.bin` models | `flutter_edge_ai_mediapipe` |
| `generateEmbedding()` / `installEmbedder()` | `flutter_edge_ai_embeddings` + `flutter_edge_ai_litertlm` (`LiteRtEmbeddingBackend`). `generateEmbedding` is `embed` since 2.3.0 |
| RAG (`addDocument` / `searchSimilar`), fastest on native | `flutter_edge_ai_rag` + `flutter_edge_ai_qdrant` |
| RAG on web (or a portable store on any platform) | `flutter_edge_ai_rag` + `flutter_edge_ai_sqlite` |

<Info>

Not sure which format your models are? In 0.16.x desktop was always `.litertlm`
(`flutter_edge_ai_litertlm`). On mobile/web check the file extension you install.
You can add **both** engine packages and let the registry route each model by its
file type.

</Info>

> **New opt-in packages since 1.2** (not migration targets from the 0.16.x
> monolith — they add new capabilities): `flutter_edge_ai_agent` (on-device agent
> skills — SKILL.md + tool-calling loop), `flutter_edge_ai_builtin_ai` (OS
> system models — Gemini Nano on Android and Web, Apple Foundation Models on
> iOS/macOS, Windows AI Foundry on Windows), `flutter_edge_ai_speech` (STT, TTS
> and a voice loop), `flutter_edge_ai_diagnostics` (memory a model costs, read
> from the OS),
> `flutter_edge_ai_onnx` (ONNX Runtime — ORT-GenAI text generation +
> plain-ORT embeddings via `dart:ffi` on native, + Web via Transformers.js /
> onnxruntime-web), and `flutter_edge_ai_llama` (GGUF chat models through
> llama.cpp, via llamadart; see [llama.cpp](/docs/llama)). Add any of them only
> if you want that feature. See
> [Getting Started](/docs/getting-started).

## Breaking: embeddings 2.0.0 — `LiteRtEmbeddingBackend` moved

<Warning>

`flutter_gemma_embeddings` **2.0.0** is a breaking change, independent of the
0.16.x → 1.0 migration above. As of `flutter_gemma_litertlm` **1.5.0**,
`flutter_gemma_embeddings` no longer ships a concrete embedding backend —
`LiteRtEmbeddingBackend` moved to `flutter_edge_ai_litertlm`. Since 2.2.0 the
package holds only the embedding tokenizer implementations; the pipeline,
pooling and isolate worker live in core.

</Warning>

If your app registers `LiteRtEmbeddingBackend()`, fix the import and bump both
dependencies:

```dart
// Before (< 2.0.0):
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';

// After (>= 2.0.0):
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
```

```
dependencies:
  flutter_edge_ai_embeddings: ^2.3.0   # tokenizer implementations (still required)
  flutter_edge_ai_litertlm: ^1.13.0     # now provides LiteRtEmbeddingBackend
```

`LiteRtEmbeddingBackend()` itself is unchanged — only where the class is
imported from. Since litertlm 1.8.0 it also needs a tokenizer registered
beside it for `.tflite` models (an EmbeddingGemma 2 `.litertlm` carries its
own): add `flutter_edge_ai_embeddings` to your pubspec and pass
`embeddingTokenizers: [GemmaEmbeddingTokenizers()]`, or `getActiveEmbedder()`
fails with an `EmbeddingLoadException` whose cause is a `StateError` naming
that step. You still depend on
`flutter_edge_ai_embeddings` (it owns the tokenizers); you just no longer import
a backend class from it. If you'd rather run embeddings over an
ONNX/ORT model instead, `flutter_edge_ai_onnx`'s `OnnxEmbeddingBackend` is a
drop-in alternative — see [Packages](/docs/packages#onnx-runtime-engine).

## Breaking: builtin_ai 0.3.0 — the native layer moved to `flutter_local_ai`

<Warning>

`flutter_edge_ai_builtin_ai` **0.3.0** (and `flutter_gemma_builtin_ai` 0.3.0 before
it) is no longer a Flutter plugin. It ships no
Kotlin/Swift/C++ and no pigeon; every OS backend now comes from
[`flutter_local_ai`](https://pub.dev/packages/flutter_local_ai), which it depends
on. **No Dart code changes** — `BuiltInAi`, `BuiltInAiEngine`,
`BuiltInAiModels`, `BuiltInAiAvailability`, `BuiltInAiUnavailableException` and
`BuiltInAiHuggingFaceResolver` keep their names and signatures — but three
build-level things move.

</Warning>

1. **`pub get` regenerates the plugin registrants and `Podfile.lock`**: this
   package leaves them, `flutter_local_ai` enters. CI that runs a frozen
   `pod install --deployment` fails until you re-commit the lockfile.
2. **The macOS deployment floor rises from 10.15 to 12.0.** A macOS 11 target
   fails resolution with a message naming the `flutter_local_ai` pod, not the
   package you added. iOS is unaffected — `flutter_local_ai` builds from 13.0 and
   core `flutter_edge_ai` still requires 15.0.
3. **`package:flutter_gemma_builtin_ai/pigeon.g.dart` is gone** with the channel
   it wrapped. It was generated plumbing that the documented API never used.

In exchange, **Windows joins the supported platforms** (AI Foundry / Phi Silica),
and `BuiltInAiModels` gains `windowsAiFoundry`, `chromePromptApi`, `all` and
`forCurrentPlatform`. Requesting vision on a backend that has none now throws at
model creation instead of dropping images mid-conversation. See [Built-in
AI](/docs/builtin-ai).

## Breaking: rag_sqlite 1.1.0 — the index does not carry over

<Warning>

`flutter_gemma_rag_sqlite` **1.1.0** replaced the Dart brute-force/HNSW store
with in-SQLite `vec0` KNN, and with it the table the index lives in:
`documents` became `vec_documents`. **An index written by 1.0.x is not read by
1.1.0+.** This shipped as a minor version with no note — if you upgraded and
your RAG answers went vague, this is why.

</Warning>

Nothing errors. `initialize()` succeeds, `getStats()` reports **0 documents**,
`searchSimilar()` returns **no hits**, and your rows are still sitting in the
old `documents` table, unread. The model then answers without the context it
used to have, which reads as the model getting worse rather than as a
migration you missed.

**Your data is recoverable.** Unlike the qdrant break below, nothing is lost:
1.0.x stored `id`, `content`, the `embedding` as a `Float32` BLOB and
`metadata` in a plain table, all still readable. Move it once at startup — no
re-embedding, no model needed:

Before copying anything, identify the exact embedder that produced the old
vectors. The profile ID must version its weights, tokenizer, pooling,
normalization, and document/query prefixes; the dimension must equal that
embedder's output dimension. Do not infer identity from the database path or
reuse the example values below without verifying them.

```dart
import 'dart:typed_data';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';   // add sqlite3 to your own pubspec

final documentsDirectory = await getApplicationDocumentsDirectory();
final databasePath = '${documentsDirectory.path}/rag.db';

// This example is exact only for the pinned EmbeddingGemma pipeline named
// here. Replace both constants if another embedder produced the legacy rows.
const sourceEmbeddingProfileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';
const sourceEmbeddingDimension = 768;
final sourceEmbeddingProfile = EmbeddingProfile(
  id: sourceEmbeddingProfileId,
  dimension: sourceEmbeddingDimension,
);

final store = SqliteVectorStore();
await store.initialize(databasePath);

final db = sqlite3.open(databasePath);
try {
  final hasLegacy = db
      .select("SELECT name FROM sqlite_master "
              "WHERE type='table' AND name='documents'")
      .isNotEmpty;

  if (hasLegacy) {
    final legacyRows = db.select(
      'SELECT id, content, embedding, metadata FROM documents',
    );
    if (legacyRows.isNotEmpty) {
      final firstEmbedding = legacyRows.first['embedding'] as Uint8List;
      final storedDimension = firstEmbedding.lengthInBytes ~/ 4;
      if (firstEmbedding.lengthInBytes % 4 != 0 ||
          storedDimension != sourceEmbeddingDimension) {
        throw StateError(
          'Legacy vectors do not match $sourceEmbeddingProfile',
        );
      }
      // Bind the verified space before the first addDocument call.
      await store.bind(VectorStoreBinding(profile: sourceEmbeddingProfile));
    }

    for (final row in legacyRows) {
      // 1.0.x wrote each element with setFloat32(..., Endian.little); read it
      // back the same way. ByteData.sublistView needs no 4-byte alignment,
      // which a raw asFloat32List view of the BLOB would.
      final bytes = ByteData.sublistView(row['embedding'] as Uint8List);
      if (bytes.lengthInBytes % 4 != 0 ||
          bytes.lengthInBytes ~/ 4 != sourceEmbeddingDimension) {
        throw StateError('Legacy row ${row['id']} has the wrong dimension');
      }
      await store.addDocument(
        id: row['id'] as String,
        content: row['content'] as String,
        embedding: List<double>.generate(
          bytes.lengthInBytes ~/ 4,
          (i) => bytes.getFloat32(i * 4, Endian.little),
        ),
        metadata: row['metadata'] as String?,
      );
    }
    db.execute('DROP TABLE documents');   // only after the loop succeeds
  }
} finally {
  db.close();
  await store.close();
}
```

Guard it with your own "already migrated" flag if you prefer, but the
`sqlite_master` check is enough: dropping the table is what makes the block a
no-op on every later launch.

There is no built-in migration call — this is a one-time fix for an upgrade
that has already happened, not an ongoing API.

## Breaking: rag_qdrant 1.3.0 — the on-disk store is not readable

<Warning>

`flutter_gemma_rag_qdrant` **1.3.0** moves onto the official `qdrant_edge`
UniFFI SDK, and **an index written by 1.2 or earlier cannot be read**. This is a
data change, not an API change: your `addDocument` / `searchSimilar` calls are
unchanged, but the documents already on the device are not.

</Warning>

An upgraded app finds no documents where its corpus used to be. 1.3.0 refuses
loudly rather than starting empty — `initialize()` throws a
`QdrantLegacyStoreException` naming the old store — so this shows up the first
time the store opens, not as silently unanswered questions later.

Remove the old store's files once, then re-index. 1.3.0 will not do it for you:
it never deletes data it cannot read, and the three entries a 1.x shard owns
(`edge_config.json`, `wal/`, `segments/`) may sit beside files of your own.

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

final store = QdrantVectorStore();
try {
  await store.initialize(path);
} on QdrantLegacyStoreException catch (e) {
  // e.message names the three entries a 1.x shard owns. Remove them with the
  // file APIs you already use for `path`, then initialize() again.
  rethrow;
}
// ...then re-add your documents, and flush() — on qdrant, points live in the
// shard's in-RAM segment until then, so a background kill loses the re-index.
```

<Warning>

Catch `QdrantLegacyStoreException`, not the base `VectorStoreException`.
`initialize()` also throws the base type when a current-layout (1.3.0 and later)
shard is present but will not open right now — a WAL held by another store, a
permission problem — and
treating that as "the old format is here" is how a recovery step can act on a
store that is perfectly fine.

</Warning>

`clear()` no longer deletes anything: it empties the shard in place, and it
refuses when a 1.x layout is present rather than removing files it cannot
read.

If your app has no re-indexing path of its own, do the re-index behind the same
progress UI you use for the first run — from the user's side this is a rebuild
of the index, not a migration they can be asked to wait through silently.

## 2. main.dart — current 2.0 composition

**Before (0.16.x):** engines were bundled into core; `initialize()` was optional.

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // (initialize was optional — only for HF token / retries)
  runApp(MyApp());
}
```

**Current (2.0):** register only AI runtimes with core. Construct RAG with its
own provider registry and own the returned index separately.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()], // flutter_edge_ai_litertlm
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
    // '' when the define is absent — an empty token still sends a bare
    // `Authorization: Bearer` header, so pass null instead.
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isNotEmpty
        ? const String.fromEnvironment('HUGGINGFACE_TOKEN')
        : null,
  );

  final rag = FlutterEdgeAiRag(
    providers: const [QdrantVectorStoreProvider()],
  );
  final index = await rag.open(
    spec: VectorStoreSpec(
      providerId: 'qdrant',
      location: ragDirectory,
    ),
    // open() loads the embedder: install it before this call.
    embedder: FlutterEdgeAiActiveEmbedder(
      profileId: 'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
          'retrieval-prefix-meanpool-l2-v1',
    ),
  );

  runApp(MyApp(ragIndex: index));
}
```

Only list what you ship. If you don't do embeddings, omit `embeddingBackends`; if
you don't do RAG, do not create an index. A vector-only or custom-embedder RAG
pipeline can run without initializing core at all. Dispose every `RagIndex`
before `FlutterEdgeAi.dispose()` or before disposing its custom embedder.

## 3. Model/chat stays compatible; RAG uses `RagIndex`

Model, session, chat, and embedding installation calls keep their API (the
embedding calls themselves changed in 2.3.0, see above). Replace the removed
singleton RAG facade with calls on the app-owned index:

```dart
// install + run a model
await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(url, token: token).install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat  = await model.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello', isUser: true));
await for (final r in chat.generateChatResponseAsync()) { /* r is a ModelResponse */ }

// embeddings + RAG
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(modelUrl, token: token)
    .tokenizerFromNetwork(tokenizerUrl, token: token)
    .install();
await index.add(id: 'doc-1', document: EmbeddingInput.text(document));
await index.flush(); // required for qdrant; Web SQLite durability fence
final hits = await index.search(query: EmbeddingInput.text(query), topK: 5);

// Shutdown order: the index borrows its embedder.
await index.dispose();
await FlutterEdgeAi.dispose(); // resets core's registries; closes no model
```

## What you'll see if you forget step 2

- Calling `getActiveModel()` with no matching `inferenceEngines` registered throws a `StateError` naming the model's `ModelFileType` and the engines that are registered — add the engine package for that file type.
- `FlutterEdgeAi.getActiveEmbedder()` or default text RAG with no matching
  `embeddingBackends` throws a clear error naming the runtime package to add.
- `FlutterEdgeAiRag.open()` with no matching registered provider throws and
  lists the registered provider IDs. Text RAG with the default active embedder
  needs `embedder: FlutterEdgeAiActiveEmbedder(profileId: …)` with a stable
  id; raw vectors need `openVectors(profile: …)`.

## Platform setup

Native setup moved to the package that owns it:

- **MediaPipe Gradle / Pod deps + the `@mediapipe/tasks-genai` web CDN** are now in `flutter_edge_ai_mediapipe` (bundled automatically on Android/iOS; add the CDN `<script>` for web).
- **The `.litertlm` native library + the `@litert-lm/core` web CDN** are in `flutter_edge_ai_litertlm`.
- **The sqlite-vec web loader** (`sqlite3.wasm` with `sqlite-vec` statically linked) is in `flutter_edge_ai_sqlite`.

The iOS/Android entitlements and manifest entries still apply when you ship an
inference engine. See the full [Installation guide](/docs/installation).

## Troubleshooting

**`dlopen` "library not found" after upgrading from `flutter_gemma_*`:** run
`flutter clean` and delete `~/Library/Caches/flutter_gemma/native` (Linux:
`~/.cache/flutter_gemma/native`, Windows: `%LOCALAPPDATA%\flutter_gemma\native`),
then `flutter pub get`.
`flutter_edge_ai_litertlm` owns the native LiteRT library;
`flutter_edge_ai_speech` consumes it transitively — it has no Native-Assets hook
of its own. `flutter_edge_ai_embeddings` has no native code at all.
