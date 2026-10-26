# flutter_edge_ai_litertlm

> **Renamed from [`flutter_gemma_litertlm`](https://pub.dev/packages/flutter_gemma_litertlm).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_litertlm/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

LiteRT-LM on-device engine for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai):
runs `.litertlm` models, EmbeddingGemma 2 `.litertlm` embeddings and LiteRT
`.tflite` embeddings. Opt-in package — add it only if you run one of them.
Android, iOS, macOS, Linux and Windows via `dart:ffi`; Web (early preview) via
`@litert-lm/core` and LiteRT.js.

This package **owns** the shared LiteRT-LM native library (`libLiteRtLm`) and
exposes the LiteRT C API bindings (`LiteRtBindings`); both are shared by
[flutter_edge_ai_speech](https://pub.dev/packages/flutter_edge_ai_speech). It
also ships the LiteRT C API embedding backend (`LiteRtEmbeddingBackend`) — see [Embeddings](#embeddings) below — over the
runtime-agnostic embedding pipeline in `flutter_edge_ai`. Tokenizers for
`.tflite` models come from
[flutter_edge_ai_embeddings](https://pub.dev/packages/flutter_edge_ai_embeddings),
which the app registers; this package does not depend on it.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-inference`, covers the `.litertlm` engine, installing a model from Hugging Face, sessions, streaming, and the platform setup for all six targets.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
);
```

`LiteRtLmEngine` handles `ModelFileType.litertlm` models; pass it alongside
other engines (e.g. `MediaPipeEngine` from `flutter_edge_ai_mediapipe`) if your app
uses both formats.

Depend on both packages (`flutter_edge_ai: ^2.5.1`,
`flutter_edge_ai_litertlm: ^1.18.0`) and install `.litertlm` files with
`fileType: ModelFileType.litertlm`: `installModel` defaults to
`ModelFileType.task`, which routes the file to MediaPipe.

> **Since 1.13.0 this package needs `flutter_edge_ai` 2.3.0 (^2.3.1 since
> 1.13.1, ^2.4.0 since 1.14.0, ^2.4.1 since 1.15.0, ^2.5.0 since 1.16.0, ^2.5.1 since 1.17.0), and 2.3.0 needs every flutter_edge_ai package
> upgraded together:**
> `flutter_edge_ai_embeddings` 2.3.0 · `flutter_edge_ai_onnx` 0.5.8 ·
> `flutter_edge_ai_mediapipe` 1.2.2 · `flutter_edge_ai_builtin_ai` 0.3.5 ·
> `flutter_edge_ai_speech` 0.5.6 ·
> `flutter_edge_ai_agent` 0.2.9 · `flutter_edge_ai_rag` 1.1.0 ·
> `flutter_edge_ai_sqlite` 2.1.0 · `flutter_edge_ai_qdrant` 2.1.0 ·
> `genkit_flutter_edge_ai` 0.9.1. Run `flutter pub upgrade`, not
> `flutter pub upgrade flutter_edge_ai_litertlm`. The
> [migration guide](https://flutteredge.ai/docs/migration) lists the API
> changes.

## Sampling

Leave `temperature`, `topK`, `topP` and `randomSeed` unset on `createSession`
or `createChat` and each comes from the sampler the `.litertlm` file ships,
else from the model family's defaults (`SamplingParams.forModelType`), else
`temperature: 0.8, topK: 40, topP: 0.95, randomSeed: 1`; a value you pass wins,
field by field. `topK: 1` or `temperature: 0` decodes greedily. Before core
2.2.0 an unset `topK` was 1, so every session decoded greedily.

- LiteRT-LM keeps the sampler of an engine's first generation, random state
  included, for every later conversation
  ([LiteRT-LM #2080](https://github.com/google-ai-edge/LiteRT-LM/issues/2080)):
  set sampling before the first generation, or close and reload the model to
  change it. A warning says so once per loaded model when a later session asks
  for other values and either set was yours.
- On web the file's sampler is not read, so unset values come from the family
  defaults. The values you pass are applied; before 1.12.0 web dropped them.
- On the NPU decoding is greedy whatever you pass; a one-time warning says so
  when you set any value.

## Context and reply length

`maxTokens` on `getActiveModel` is the whole context window — prompt, history
and reply — not the reply length. On CPU and GPU a value below 1024 is raised
to 1024, because the published bundles fail to allocate below it; on the NPU it
is passed through, so use the context size the bundle was compiled for. Cap the
reply with `createSession(maxOutputTokens:)`.

## Multimodal order

A user message with an image or audio reaches the model as parts, and the
model's chat template renders them in the order they arrive. Since 1.14.0 (core
2.4.0) that order is chosen by the model type:

| Model type | Order | Why |
|---|---|---|
| `ModelType.gemma4` (E2B, E4B, and the NPU bundles, which share the template) | images, text, audio | [Gemma 4 model card](https://huggingface.co/google/gemma-4-E2B-it), section 4 "Modality order": images before the text, audio after it |
| every other type | images, audio, text | the order before 1.14.0; [Gemma 3n](https://huggingface.co/google/gemma-3n-E2B-it) answered the same either way, and [VibeVoice-ASR](https://huggingface.co/litert-community/VibeVoice-ASR-BitNet) needs its audio first |

Pass another order with `getActiveModel(multimodalOrder:)` when your model's
template expects one:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  supportAudio: true,
  multimodalOrder: MultimodalOrder.imagesAudioText,
);
```

`MultimodalOrder(images:, audio:)` places each medium before or after the text
(`MediaPosition.beforeText` / `afterText`). Media on the same side keep images
before audio, several images keep their order, and a message without text still
sends its empty text part, so an audio-only message is the same in every order.
Changing the order rebuilds the model. The web engine sends no media to an LLM,
so it has nothing to order.

Measured on Developer Device Platform phones on 2026-10-14 and 2026-10-15.
Every spoken request ran in both orders, with a fresh chat per turn,
`temperature: 0.6`, `topK: 40`, and clips spoken by four macOS voices. A turn
counts as answered when the model did what was asked, with the right tool when
the chat had tools:

| Model, phone, backend | Turns | Audio before the text | Audio after the text |
|---|---|---|---|
| Gemma 4 E2B, Galaxy S24, GPU, chat with two tools | 56 | 44 | 50 |
| Gemma 4 E2B, Galaxy S24, GPU, plain chat | 32 | 29 | 29 |
| Gemma 4 E2B, Galaxy S24, NPU (SM8650), plain chat | 32 | 29 | 32 |
| Gemma 4 E4B, Galaxy S25 Ultra, GPU, chat with two tools | 56 | 45 | 53 |
| Gemma 4 E4B, Galaxy S25 Ultra, GPU, plain chat | 32 | 29 | 32 |
| Gemma 3n E2B, Galaxy S24, GPU, plain chat | 32 | 32 | 32 |

- Over the 244 spoken Gemma 4 turns (the rows above and 36 questions about a
  photo), paired clip by clip, 22 were answered only with the audio after the
  text and 2 only with it before (McNemar, p < 0.001). On plain spoken requests
  Gemma 4 failed 23 times in 160 with the audio first and 8 times with it last.
  The failures were refusals ("I don't have any audio input") and questions
  sent to the wrong tool.
- Transcription, photo questions and time to first token did not get worse
  with the audio last. Typed questions, the same message in both orders,
  differed by one turn in twelve: that much is sampling noise.
- VibeVoice-ASR transcribing 80 clips: word error rate 0.19 with the audio
  before its prompt and 2.55 after it (20 empty and 13 runaway transcripts).
  That is why the order follows the model rather than changing for every
  model.

## Deciders from a model trained on the decision

A `.litertlm` tuned by [LiteTune](https://pypi.org/project/litetune/) 0.5.0 or
later for one decision — a Choice, Noul (yes/no) or Score (a level) question —
carries that decision in a `litetune.decision` section, and
`InferenceModel.createDecider` reads it (core's experimental Decider API):

```dart
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.cpu,
);
final decider = await model.createDecider(
  question: 'Which emotion does the text express?',
  options: [DeciderOption('sadness'), DeciderOption('joy'), /* … */],
  calibration: const InferenceDeciderCalibration.fromModel(),
);
```

`fromModel()` takes the temperature, threshold and none option from the file;
another question or option set is refused with `ArgumentError`. LiteTune
0.5.0's `bundle` prints only the `options:` part of the call. Each decision
renders the prompt with the model's chat template, prefills it, and scores each
option's shortest unique prefix as the model's reply through LiteRT-LM's
session API (`run_text_scoring`, with a checkpoint and a rewind between
options), on a background isolate and in turn with any chat on the same
engine; a cancel stops it between two options, and so does closing the model.
Native platforms, CPU only: the web, a model loaded on the GPU or the NPU, and
a file without the section are refused with `DeciderUnsupportedException`; an
input whose prompt does not fit `maxTokens` with `ArgumentError`. Measured on
an Apple M4 Pro CPU with LiteTune's golden packs (google/gemma-3-270m-it,
int8): 120–190 ms per decision, and the same top option as LiteTune's PyTorch
reference on every row but near-ties. Android, iOS, Linux and Windows use the
same C calls and are not measured yet. The answers, Noul and Score included:
[Decisions](https://flutteredge.ai/docs/decisions#deciders-from-a-language-model).

## Install from a Hugging Face repo (`litertlm_manifest.json`)

Repos that ship a
[`litertlm_manifest.json`](https://github.com/john-rocky/hf-to-litertlm/blob/main/manifest/SCHEMA.md)
deployment manifest describe every `.litertlm` file they contain — which
backends each is verified on, which file a given platform should pick, sha256/
size identity, and session guidance. `LitertlmManifestResolver` reads it so an
app installs "the right file for this device" without hardcoding filenames:

```dart
import 'dart:math' show max;

// LiteRtLmEngine carries this resolver, so registering the engine registers
// it too. Pass huggingFaceResolvers: only to override — e.g.
// [LitertlmManifestResolver(revision: 'abc123')] to pin a commit.
await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

final r = await FlutterEdgeAi.resolveHuggingFace(
    'litert-community/Qwen3-4B-Thinking-2507',
    fileType: ModelFileType.litertlm);
await FlutterEdgeAi.installModel(
      // The manifest types 2507 as qwen3; ModelType.qwen is right for it.
      // For other repos, r.modelType ?? ModelType.general.
      modelType: ModelType.qwen,
      fileType: r.fileType,
    )
    .fromNetwork(r.url) // authoritative: carries the resolver's revision pin
    .install();
final model = await FlutterEdgeAi.getActiveModel(defaults: r.runtime);
final session = await model.createSession(
  enableThinking: r.runtime.thinkingDeclared ?? false,
  // minOutputTokens is a floor, not a cap: keep the app's own budget unless
  // the manifest asks for more.
  maxOutputTokens: max(1024, r.runtime.minOutputTokens ?? 0),
);
```

Everything the manifest returns is an overridable default (explicit argument >
manifest > SDK default); `r.notes` carries platform caveats and known issues
worth surfacing to developers. Repos without a manifest keep working through
`installModel(...).fromHuggingFace(repo, file: ...)`.

To resolve and install in one step, omit `file`: `fromHuggingFace(repo)` reads
the manifest at install time, installs the revision-pinned variant, and returns
the same defaults on `InferenceInstallation.runtime` (plus `notes`). The
two-step form above stays the offline-safe one — manifest mode needs the network
on every install, because the variant's filename is only known after the fetch.

## Embeddings

`LiteRtEmbeddingBackend` runs two kinds of embedding model:

| Model file | Platforms | Tokenizer | Longest input |
|---|---|---|---|
| EmbeddingGemma 2 text, images and audio, one `.litertlm` | Android, iOS, macOS, Linux, Windows; Web via `@litert-lm/core` (WebGPU); per-SoC bundles on Qualcomm NPUs (Android, Linux arm64), Google Tensor G5/G6 (Android, opt-in), MediaTek MT6991/MT6993 (Android, opt-in, not run on device yet) and Intel Panther Lake NPUs (Windows x64) | inside the bundle | 1024 tokens |
| EmbeddingGemma 1, Gecko: `.tflite` + a tokenizer file | Android, iOS, macOS, Linux, Windows; Web via LiteRT.js | `flutter_edge_ai_embeddings` | the model's sequence length (256 for a `seq256` file) |

```dart
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()], // .tflite models only
);

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vector = await embedder.embed(
  EmbeddingInput.text('How do I reset the device?'),
  taskType: TaskType.retrievalQuery,
);
```

A `.tflite` model needs both lists and both packages: this one brings the
backend, and `flutter_edge_ai_embeddings` brings the tokenizers it asks core
for. On web the tokenizer list is unused — the LiteRT.js bundle tokenizes in
JS. The pipeline the backend plugs into — the embedding pass SPI, the host that
runs a pass off the UI isolate, and the pooling — lives in `flutter_edge_ai`.
On web it runs via LiteRT.js instead; see
[Embeddings on web](#embeddings-on-web) below for the four files and the
`<script>` tag your app needs.

`taskType` is required and prefixes the text: `retrievalQuery` and
`retrievalDocument` for search, `none` for no prefix, and
`questionAnswering`, `factChecking`, `codeRetrieval`, `classification`,
`clustering`, `sentenceSimilarity`. Every model here gets the same prefix for
the same task, native and web.

An input longer than `embedder.maxInputTokens` — task prefix, BOS and EOS
included — is never truncated: `embed` fails with
`EmbeddingInputTooLongException`. Every embedding error arrives as a failed
future (`EmbeddingException` and its subclasses).

### EmbeddingGemma 2

EmbeddingGemma 2 ships as one `.litertlm` bundle that carries its own
tokenizer, so it installs without `tokenizerFrom…()` and needs neither
`flutter_edge_ai_embeddings` nor `embeddingTokenizers:`. The text-only 270m
bundle is the one for text; the 440m adds images ([below](#embeddinggemma-2-images))
and the 740m adds audio ([below](#embeddinggemma-2-audio-and-combined-inputs)).
The repositories are not gated:

```dart
const revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$revision/'
      'embeddinggemma-2-text-270m.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vector = await embedder.embed(
  EmbeddingInput.text(chunk), // core adds the task prefix
  taskType: TaskType.retrievalDocument,
);
```

- **Android, iOS, macOS, Linux and Windows, and the web (1.13.1).** On the web
  the bundle runs through `@litert-lm/core`'s `EmbeddingEngine` on WebGPU,
  which needs one more line in `web/index.html` — see
  [Web setup](#web-setup-early-preview) — and a browser with WebGPU.
- **Text on every bundle; images on the 440m and the 740m; audio on the
  740m.** Natively all from 1.13.1; on the web text and images from 1.13.1,
  audio and combined inputs from 1.13.2. On the 270m,
  `getActiveEmbedder(supportImage: true)` fails with `EmbeddingLoadException`
  naming the 440m bundle — natively from the bundle's ModelInfo before any
  engine or cache is made, on the web when `EmbeddingEngine.create` refuses it.
  On the 270m and the 440m `supportAudio: true` fails naming the 740m — read
  from the bundle's own header before any engine or cache is made, on the web
  too (a few KB of the installed file).
- **At most 1024 tokens per input**, task prefix, BOS and EOS included
  (`maxInputTokens == 1024`). Keep chunks at 512 tokens or fewer: memory grows
  with the input length (on an M4 Pro Mac about +170 MB at 128 tokens, +340 MB
  at 512 and +560 MB at 1024). A longer input fails with
  `EmbeddingInputTooLongException` whose `actualTokens` is the exact count.
  Natively (from 1.13.1) the engine reports it from a truncated run; on the web
  it reports it after running the whole input in 1024-token windows (WebGPU
  averages them instead of truncating; the averaged vector is never returned).
  Either way an over-long input costs a full embedding before it is refused.
  Split before embedding.
- **CPU natively, WebGPU on the web.** `activeBackend` is
  `PreferredBackend.cpu` on Android, iOS and desktop and
  `PreferredBackend.gpu` on the web; `preferredBackend` is not applied — except
  `npu`, which this bundle refuses: the NPU runs the per-SoC bundles
  ([below](#embeddinggemma-2-on-a-qualcomm-npu)). The web has no CPU path for
  these bundles: the CPU (WebAssembly) backend of `@litert-lm/core` 0.18.0
  cannot read their external weights, so a browser without WebGPU (no
  `navigator.gpu`, or no GPU adapter) fails `getActiveEmbedder()` with an
  `EmbeddingLoadException` that says so, before any engine is created. Web
  vectors come from WebGPU and differ slightly from the native CPU ones:
  measured min cos about 0.995 for text and 0.998 for images (Chrome 155,
  Tesla T4). Retrieval across platforms holds: web text queries find natively
  embedded images and native queries find web-embedded images, top-1 10/10 on
  the example's ten scenes.
- **Disk:** the 165 MB bundle plus a 71 MB weight cache the engine writes at
  its first load. The 440m bundle adds a 218 MB vision cache and the 740m
  bundle writes 385 MB of caches in total, even for text-only use. The cache
  lives in
  the app's cache directory: it is never backed up, and if the OS clears it the
  next load writes it again. The engine opens one cache file per tower when it
  loads. When it cannot create that file (a path too long for the platform,
  such as past Windows' 260-character `MAX_PATH`, a directory the app cannot
  write to, or possibly no free space at all), that tower runs anyway, slower
  to load and, measured on the 270m, with about 290 MB more memory, and the
  package only prints a warning. A disk that fills while the cache is being
  written is different: the engine (XNNPack) aborts the process in native
  code, and no flag can catch that. On the web there is no weight cache: the
  bundle sits in the browser's storage and the engine rebuilds its weights at
  every load.
- **`requireWeightCache` (flutter_edge_ai_litertlm 1.14.0).** To make a load
  that wrote no weight cache a failure, register
  `LiteRtEmbeddingBackend(requireWeightCache: true)`: `getActiveEmbedder()`
  then throws an `EmbeddingLoadException` naming the cache directory, the
  length of the cache file path and the likely causes, and no engine is left
  running. One tower's cache missing beside the others stays a printed
  warning. It applies on CPU, and on the NPU only to a load with declared
  audio, whose tower runs on CPU. For a `.tflite` embedder and on the web it
  is accepted and ignored, which a debug build says once. It takes effect
  when an embedder is loaded: one already loaded is kept.
  - **The warning is invisible on Windows release builds.** It is a `print`,
    and a Windows release build started from Explorer has no console. Windows
    desktop apps that care should pass `requireWeightCache: true`.
  - **What a refusal costs.** It comes from the load, after core has closed
    the embedder it held, so the embedder that was working is gone too. With
    the RAG `FlutterEdgeAiActiveEmbedder`, every operation re-resolves the
    model, so each call repeats the engine create (and its attempt at the
    cache) before it refuses.
- EmbeddingGemma 1 and 2 both produce 768-dimensional vectors in different
  embedding spaces: never mix them in one vector store.

### EmbeddingGemma 2 images

The 440m bundle carries the 270m's text tower (the same text vectors) plus a
vision encoder, so one model embeds text and images and a text can find a
photo. Declare images when you get the embedder:

```dart
const visionRevision = 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-vision-440m-litert-lm/resolve/$visionRevision/'
      'embeddinggemma-2-text-vision-440m.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
final photo = await embedder.embed(
  EmbeddingInput.image(await uprightAndSmall(photoBytes)), // below
  taskType: TaskType.retrievalDocument, // prefixes reach text only
);
final query = await embedder.embed(
  EmbeddingInput.text('a red bicycle'),
  taskType: TaskType.none, // a text query over images works best raw
);
```

**Pass upright, downscaled images.** LiteRT-LM decodes the file itself and
ignores EXIF orientation, so a portrait photo from a phone camera — stored
sideways with an orientation tag — is embedded lying on its side (measured: cos
0.89 against the same picture upright). It also decodes at full size, which a
12 MP photo pays for in time and memory the model does not need: it scales
every image down to its vision budget anyway. Flutter's codec fixes both:

```dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// [photo] upright (Flutter applies the EXIF orientation) and at most
/// 1024 px on its long side, as PNG.
Future<Uint8List> uprightAndSmall(Uint8List photo) async {
  final codec = await ui.instantiateImageCodecWithSize(
    await ui.ImmutableBuffer.fromUint8List(photo),
    getTargetSize: (w, h) => math.max(w, h) <= 1024
        ? const ui.TargetImageSize()
        : w >= h
        ? const ui.TargetImageSize(width: 1024)
        : const ui.TargetImageSize(height: 1024),
  );
  final image = (await codec.getNextFrame()).image;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  return png!.buffer.asUint8List();
}
```

It also converts what Flutter decodes and the engine does not (WebP; HEIC on
Android). The example app writes BMP instead of PNG — cheaper to write and to
read back — and gets the camera photo's vector within cos 0.998 of the upright
one. The same code runs on the web (the browser decodes, through CanvasKit or
skwasm); there are no isolates there, so the example writes its BMP on the
page.

- **Formats the engine decodes:** JPEG, PNG, GIF and BMP. HEIC, WebP, TIFF and
  AVIF fail with `EmbeddingFormatNotSupportedException` (which names the
  detected and the accepted formats) before anything is sent. A corrupt or
  truncated file of an accepted type fails with `EmbeddingEngineException`
  (`nativeCode` 3 natively; on the web the message carries the runtime's
  reason) and the embedder keeps working. One image per vector, unless you
  send several as one combined input (natively, from 1.13.1;
  [below](#embeddinggemma-2-audio-and-combined-inputs)).
- **Vision budget:** 140 tokens per image by default, the closest to the
  reference model (min cos 0.985 on our test images).
  `LiteRtEmbeddingBackend(visionTokensPerImage: 70)` — what the model card and
  Google AI Edge Gallery use — is about twice as fast with slightly lower
  fidelity (min cos 0.970). Any other value fails with
  `EmbeddingLoadException`. Text vectors do not depend on it. Image vectors
  do, so give an image store an id that names the budget: the text profile id
  plus `-vis140` (or `-vis70`).
- **Next to an LLM on the web** the vision encoder does not fit: see
  [Web setup](#web-setup-early-preview). Close the `.litertlm` LLM before
  loading the 440m with images, or embed text only.
- **Cost** (CPU, measured): a 388 MB bundle; at every load the engine writes a
  218 MB vision weight cache next to the 71 MB text cache in the app's cache
  directory, also when you only embed text. The first image adds about 385 MB
  of RAM on an M4 Pro Mac and about 500 MB on a Pixel 8. Per image at 140
  tokens: about 0.35 s on an Apple-silicon Mac, about 2 s on an Android flagship
  (Pixel 8 Pro 1.8 s, Pixel 8a 2.3 s), more on mid-range phones and rising
  under sustained load; 70 tokens takes about half. On the web (WebGPU, Tesla
  T4) an image takes about 0.33 s and a short text about 0.12 s. LiteRT-LM's
  thread setting reaches the text tower only; images run with its default
  threads. A 440m loaded for text alone still loads its vision tower: for
  text use the 270m.
- The example app's **Image Search** screen indexes photos (or ten bundled
  sample pictures) in a RAG image index and searches them by text and by
  photo; choose "EmbeddingGemma 2 Text + Vision (440M)" under Embedding Models
  first.

### EmbeddingGemma 2 audio and combined inputs

The 740m bundle carries the 440m's text and vision towers (the same text and
image vectors) plus an audio encoder, so a text can find a spoken sentence or a
sound, and one vector can hold several parts — a photo with its caption, a clip
with a note. Natively from 1.13.1, on the web (WebGPU) from 1.13.2. Declare
what you send when you get the embedder:

```dart
const audioRevision = '24d962e906c7d332c6428e71c9676855024569e2';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-740m-litert-lm/resolve/$audioRevision/'
      'embeddinggemma-2-740m.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
final clip = await embedder.embed(
  EmbeddingInput.audio(wavBytes),
  taskType: TaskType.retrievalDocument, // prefixes reach text only
);
final query = await embedder.embed(
  EmbeddingInput.text('turn off the kitchen lights'),
  taskType: TaskType.none, // a text query over media, as rag sends it
);

// Several parts, one vector (flutter_edge_ai 2.3.1):
final note = await embedder.embed(
  EmbeddingInput(text: 'kitchen', audio: wavBytes),
  taskType: TaskType.retrievalDocument,
);
```

- **Formats the engine decodes:** WAV, MP3 and FLAC, any sample rate and
  channel count — the engine mixes down to mono and resamples to 16 kHz. Ogg
  and M4A fail with `EmbeddingFormatNotSupportedException` before anything is
  sent; a corrupt file of an accepted type fails with
  `EmbeddingEngineException` (natively `nativeCode` 2; on the web it carries
  the runtime's message, "Failed to initialize miniaudio decoder") and the
  embedder keeps working. The web decodes with the same miniaudio, compiled to
  WebAssembly. One clip per vector.
- **Length:** about 25 tokens per second of audio, so a clip of up to about
  40 seconds fits the 1024-token cap; a 60-second clip fails with
  `EmbeddingInputTooLongException(maxInputTokens: 1024, actualTokens: 1504)`,
  natively and on the web alike. Split long recordings.
- **Combined inputs:** `EmbeddingInput(text:, images:, audio:)` puts the text
  (with its task prefix), then the images in order, then the audio into one
  vector — that order whatever order you write the arguments in. Several
  images in one input are a combined input too. Declare every medium you send
  (`supportImage: true, supportAudio: true`); the cap counts all parts
  together (about 140 tokens per image), on the web too.
- **Cost** (CPU, measured on an M4 Pro Mac): a 485 MB bundle; at every load the
  engine writes 385 MB of weight caches (text 71 MB, vision 218 MB, audio
  95 MB) in the app's cache directory, also when you only embed text; about
  0.2–0.3 s per 3-second clip. On the web (WebGPU, Tesla T4, Chrome 155)
  `getActiveEmbedder(supportAudio: true)` on the 740m took about 17 s, of
  which the engine's create is about 5 s (9 s with images too; no weight
  cache there); a 3-second clip takes about 0.3 s, the first one about 4 s
  while WebGPU compiles. The audio tower runs on WebGPU: on the CPU
  (WebAssembly) it takes about 18 s per clip, on the page's main thread. Not
  measured next to a `.litertlm` LLM on the same page. For text use the 270m,
  for text and images the 440m.
- **Index ids:** audio vectors do not depend on the vision budget, so an audio
  store keeps the text profile id (rag tells the stores apart by their
  `documents` modality).
- **Audio vectors are not bit-portable.** The audio encoder quantizes its
  activations to 8 bits, so a difference in the last bit of a float — another
  CPU kernel, or one sample of the clip changed by 1 — can move a clip's
  vector by up to cos 0.05. Text and image vectors do not move that way. Our
  native build and Google's `litert-lm` Python wheel give identical text
  vectors and audio vectors within cos 0.97 (the wheel even varies by thread
  scheduling run to run); one build is deterministic on one platform. The web
  (WebGPU) is within cos 0.97 of both. What holds across builds is retrieval:
  a text finds its clip on every build we measured, the web included, and a
  web query finds the clips embedded natively.

`EmbeddingModel.activeBackend` is `cpu` on native and `gpu` for EmbeddingGemma
2 on the web, and `npu` for an EmbeddingGemma 2 per-SoC bundle on a Google
Tensor NPU ([below](#google-tensor-npu-on-android-opt-in)), MediaTek NPU
([below](#mediatek-npu-on-android-opt-in)), Qualcomm NPU
([below](#embeddinggemma-2-on-a-qualcomm-npu)), or Intel NPU
([below](#embeddinggemma-2-on-an-intel-npu-windows)); any other
`preferredBackend` is not applied. For EmbeddingGemma 1 on the web it is `null` and LiteRT.js
picks: `window.getLiteRtEmbeddingAccelerator()` names where
the output buffer lived after the first embedding, and
`window.getLiteRtEmbeddingFullyAccelerated()` says whether the graph landed
entirely on the requested accelerator — `false` also when LiteRT silently
recompiled a WebGPU request for WASM.

### EmbeddingGemma 2 on a Qualcomm NPU

Google publishes every EmbeddingGemma 2 bundle a second time, compiled for one
SoC's NPU, in the same repositories:
`embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm`,
`embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm`, and so on. Such
a bundle runs only on that SoC's NPU. This package runs it on **Qualcomm
Android (arm64) and Qualcomm Linux arm64**:

```dart
const revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$revision/'
      'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder(
  preferredBackend: PreferredBackend.npu,
);
assert(embedder.activeBackend == PreferredBackend.npu);
```

- **Opt in to the Qualcomm stack**, as for the LLM NPU path:
  `qualcomm_npu: true` under `hooks: user_defines: flutter_edge_ai_litertlm:`
  ([Qualcomm NPU](#qualcomm-npu-on-android-and-linux-arm64-opt-in)).
- **Pick the bundle for the device's SoC.** Verified on device: SM8850
  (Snapdragon 8 Elite Gen 5), SM8650 (Snapdragon 8 Gen 3) and QCS8275 (Arduino
  VENTUNO Q). Google also publishes SM8550, SM8750, Tensor G5/G6, MediaTek
  MT6991/MT6993 and Intel PTL builds; the Qualcomm ones load here but are not
  verified by us, Tensor G5/G6 runs on matching Pixels in apps built with
  `google_tensor_npu` ([below](#google-tensor-npu-on-android-opt-in)), the
  G6 270m and 440m run on a Pixel 11, Intel PTL runs on Windows
  ([below](#embeddinggemma-2-on-an-intel-npu-windows)), and MediaTek
  MT6991/MT6993 are accepted in apps built with `mediatek_npu`
  ([below](#mediatek-npu-on-android-opt-in)) but not run on such a device
  yet.
  What a bundle is compiled for is read from the bundle itself, not from its
  name.
- **Fast, and close to — not equal to — the CPU vectors.** Measured on an
  SM8650 (Galaxy S24): a text in about 9 ms (53 ms on its CPU), an image in
  about 0.31 s, the 270m loaded in 0.85 s. Against the CPU bundle, the cosine is
  0.79–0.86 for sentences of a few words, 0.92 at about 50 words and 0.99 from
  about 200; images 0.86–0.88. Retrieval within the NPU's own space holds: ten
  of ten captions find their picture, every query its document.
- **Nothing switches backend.** NPU and CPU vectors are not interchangeable,
  so every mismatch is an `EmbeddingLoadException` that says what to do: a
  per-SoC bundle without `PreferredBackend.npu`; the generic bundle with `npu`;
  `npu` on iOS, macOS, Linux x64 or the web; a Qualcomm bundle on Windows; an
  app built without `qualcomm_npu`; a device without a reachable Qualcomm NPU;
  a bundle the NPU cannot run (another SoC's — the load embeds one test text
  to find out). A loaded embedder is never handed to a request for the other
  backend.
- **Give an NPU index its own profile id.** Vectors from the SM8850 bundle and
  from the generic bundle live in different spaces, so a RAG store built with
  one never takes the other's queries. The example app uses the CPU text id
  plus `-npu-<soc>` (`embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850`,
  and `…-vis140` for an image index); the 270m and the 440m of one SoC share
  it, because their text towers are byte-identical.
  `FlutterEdgeAiActiveEmbedder.forActiveModel` keys on the installed file name,
  so it separates them by itself.
- Text up to 1024 tokens (the bundles carry no longer signature), and images
  on the 440m, as on CPU; audio on the 740m's per-SoC bundles from 1.13.2,
  with their audio encoder on the CPU (verified on SM8850, Galaxy S26+).
- On Linux the NPU calls run with SIGPROF blocked, as the LLM engine's create
  does: QNN does not survive the debug VM's profiler signal. Linux needs
  native-v0.18.0-e or newer, which reads the bundles' external weights by path.

### EmbeddingGemma 2 on an Intel NPU (Windows)

Google's `…_Intel_PTL.litertlm` bundles are compiled for the Intel Panther Lake
NPU. From 1.13.2 this package runs them on **Windows x64** with
`PreferredBackend.npu`, through the Intel stack (`LiteRtDispatch.dll`, OpenVINO
and TBB) that every Windows x64 build already carries beside the executable — no
opt-in flag:

```dart
const revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$revision/'
      'embeddinggemma-2-text-270m_Intel_PTL.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder(
  preferredBackend: PreferredBackend.npu,
);
```

- **The load checks the NPU.** It embeds one test text and refuses unless it
  gets a valid vector, so a PC without an Intel NPU, or one the stack cannot
  drive, gets an `EmbeddingLoadException` rather than wrong vectors.
- **Measured on a Panther Lake PC** (2026-10-21, OpenVINO 2026.4.1): the 270m
  loads in about 0.9 s (the generic bundle: 0.3 s on the same PC's CPU) and
  returns 768-dimensional vectors; a matching pair scores cos 0.913 (0.914 on
  the CPU), an unrelated one 0.629 (0.628). These are similarities within
  each backend: how close an NPU vector is to the CPU one is not measured. The
  440m is not measured.
- **A weight bank in `%TEMP%`.** The load copies the bundle's weights to
  `litert_ov_bank_<hex>.bin` (74.5 MB for the 270m) and the close deletes it.
  From 1.17.0 the embedder marks it as its own while it is open, so the next
  Intel NPU load can delete one an app left behind; see
  [Windows NPU](https://flutteredge.ai/docs/desktop).
- The same rules as on Qualcomm: refused without `npu`, refused on any other
  platform (an Intel bundle on Android or Linux, a Qualcomm bundle on Windows),
  refused with the reason when `LiteRtDispatch.dll` is not beside the
  executable, and never moved to CPU.
- **Its own profile id.** The example app uses the CPU text id plus `-npu-ptl`
  (and `…-vis140` for an image index); the 270m and the 440m share it, because
  their text towers are byte-identical.

## Embeddings on web

EmbeddingGemma 2 (`.litertlm`) on the web needs no files from this package —
only the `window.EmbeddingEngine` line in [Web setup](#web-setup-early-preview).
The rest of this section is about EmbeddingGemma 1 and Gecko (`.tflite`).

On web, `flutter_edge_ai_litertlm`'s `.tflite` embedding backend runs via LiteRT.js. Copy
all four files from this package's `web/` into your app's `web/`, next to
`index.html` — `litert_embeddings.js` imports the other three by relative path,
so they have to sit together:

```
litert_embeddings.js  sentencepiece.js  litert.js  tensorflow.js
```

They are four pieces of one bundle (the entry plus three vendor chunks), built
together by `tool/web_build`, so never mix them across package versions. Find
this package's directory with
`grep -A1 '"name": "flutter_edge_ai_litertlm"' .dart_tool/package_config.json`,
then load the entry module from `web/index.html`:

```html
<script type="module" src="litert_embeddings.js"></script>
```

Upgrading from an earlier version: delete the copies in your app's `web/` and
re-copy all four from this package. 1.13.0 changed the bundle's API: Dart now
builds the task prefix, so every `TaskType` gets the prefix and token ids it
gets on native, and the bundle reports the model's input limit instead of
truncating.
A copy from an earlier version fails `getActiveEmbedder()` with an
`EmbeddingLoadException` that names `litert_embeddings.js`. Before `flutter_gemma_litertlm` 1.8.0 they
came from `flutter_gemma_embeddings`, and the copies you have are built against an older
`@litertjs/core` than the runtime this version loads. If you built your own
`web/wasm/`, either delete it and take the CDN default or rebuild it from the
version in `LiteRtWebRuntime.pinnedVersion`.

> Loading `litert_embeddings.js` straight from a CDN with a
> Subresource-Integrity hash — which an older README suggested — cannot work:
> the module's three imports resolve against the CDN path, where they do not
> exist, so the module never executes and every embedding call fails on an
> undefined global. SRI would not have covered the imports either.

### The WASM runtime

LiteRT.js loads a WASM runtime when the embedder loads (`getActiveEmbedder()`) —
`litert_wasm_internal.js`, or `litert_wasm_compat_internal.js` on a browser
without relaxed SIMD, each with a ~9 MB `.wasm` beside it. Since
`flutter_gemma_litertlm` 1.8.0 they come from the pinned `@litertjs/core` build on jsDelivr by default — nothing to
install, and nothing this package has to carry into every native-only app.

To serve them yourself (offline, an air-gapped deploy, or a CSP that forbids
third-party script), copy `node_modules/@litertjs/core/wasm/` into your app's
`web/wasm/` and point the package at it before the first embedder loads:

```dart
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

LiteRtWebRuntime.wasmPath = '/wasm/';
```

Those files come from `@litertjs/core` — `npm i @litertjs/core@2.6.0` in a
scratch directory, then copy its `wasm/`.

Set the prefix before the first `getActiveEmbedder()` — the runtime is loaded once and
cached, so a later assignment is ignored. LiteRT.js inserts the separator when
it joins the prefix with the file name, so the trailing slash above is
convention, not a requirement; the value is root-absolute, and an app served
under a base href other than `/` needs `/my-app/wasm/` or a full URL.

Pin `@litertjs/core` to `LiteRtWebRuntime.pinnedVersion` if you vendor it. The
runtime and this package's `web/litert.js` are two halves of one release —
`litert.js` calls that release's WASM entry points by name — and a mismatch
fails when the embedder loads with something that does not mention versions at
all: a runtime older than the glue gives
`Cannot read properties of undefined (reading 'create')`.

Serving it yourself is also the answer if a third-party script in your app's
runtime path is not acceptable to you: LiteRT.js injects the `<script>` itself,
so the CDN copy carries no Subresource-Integrity hash.

Whatever host you use must send `Access-Control-Allow-Origin` (LiteRT.js sets
`crossOrigin="anonymous"` on the script it injects) and serve `.wasm` as
`application/wasm`.

Native embeddings need no web files; the platform setup under
[Platforms](#platforms) still applies.

## Web setup (early preview)

`.litertlm` web inference runs via `@litert-lm/core` (WebGPU/WASM). Load a
model's web export (`gemma-4-E2B-it-web.litertlm`, not `gemma-4-E2B-it.litertlm`).
It is text-only: an image or audio message throws `UnsupportedError`, because
the JS API creates the LLM engine with no vision or audio executor, and
`loraPath` throws too. `createSession(maxOutputTokens:)` is honoured here as it
is on native.
Add the handshake below to your app's `web/index.html` `<head>` — the ESM doesn't
assign window globals and module scripts are deferred, so Dart awaits
`window.litertLmReady` (which resolves to the `Engine` constructor):

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm');
  window.Engine = m.Engine;
  window.EmbeddingEngine = m.EmbeddingEngine;
  return m.Engine;
})();
</script>
```

`window.EmbeddingEngine` (1.13.1) is what EmbeddingGemma 2 `.litertlm`
embedders run on, on WebGPU: text and images, and from 1.13.2 audio and
combined inputs (no further line). A page without that line fails
the embedder's load with an `EmbeddingLoadException` that names it; so does a
browser without WebGPU, which has no fallback here (the CPU path of
`@litert-lm/core` 0.18.0 cannot read these bundles' external weights). The LLM
engine does not need the line.

An LLM and an EmbeddingGemma 2 embedder on the same page share one WebAssembly
module and one WebGPU device, so they take turns and their GPU memory adds up:
an embedding, or an embedder's load, waits while a reply is being generated
(until its stream ends, even if you stopped listening), and a reply waits for
an embedding in progress. The module has 4 GB of memory (WebAssembly is
32-bit), and the 440m's vision encoder does not fit in it next to Gemma 4 E2B
(measured: the vision engine alone takes about 3.3 GB): whichever loads
second fails, the embedder with an `EmbeddingLoadException` that says to close
the LLM first. A text-only embedder — the 270m, or the 440m without
`supportImage` — loads next to the LLM.

Native platforms need no web setup.

## Platforms

| Platform | Support |
|----------|---------|
| Android  | ✅ FFI (GPU via OpenCL; NPU on Qualcomm, Google Tensor G5/G6 or MediaTek — each opt-in, below) |
| iOS      | ✅ FFI (GPU via Metal on device; CPU on simulator) |
| macOS / Linux | ✅ FFI (GPU via Metal / Vulkan; NPU on Qualcomm Linux arm64 — opt-in, below) |
| Windows  | ✅ FFI on x64 (CPU + GPU via DirectX 12 + Intel NPU); ARM64 has no native archive, see [Troubleshooting](#windows-arm64-litert-lm-inference-is-not-available) |
| Web      | ⚠️ early preview via `@litert-lm/core` (CDN; LLMs text-only; EmbeddingGemma 2 text, images and audio on WebGPU) |

The native library (`native-v0.18.0-g`, LiteRT-LM v0.18.0) is fetched at build
time by `hook/build.dart` from a SHA256-verified GitHub release. The app still
needs its platform setup: Android `minSdk 30`, iOS 15.0 and the memory
entitlements, and on macOS a `post_install` block in `macos/Podfile`, with Swift
Package Manager turned off for an app that had no Podfile ([Desktop → macOS](https://flutteredge.ai/docs/desktop#macos)).
Without them the first model load fails; the error contains
`flutter_edge_ai_litertlm: LiteRT-LM did not load on macOS` and names the fix
([#689](https://github.com/DenisovAV/flutter_edge_ai/issues/689)). See
[platform setup](https://flutteredge.ai/docs/installation#3-platform-specific-setup).

`PreferredBackend.npu` is attempted only for a bundle compiled for an NPU, and
only on Windows, on Google Tensor G5/G6 Pixels with Android 16 or later (not a
`BP2A` build), on MediaTek Android devices (Android 12 or later) whose
NeuroPilot adapters open in the app, on
Android devices with Qualcomm FastRPC (`libcdsprpc.so`), and on Qualcomm Linux
arm64 boards; the Tensor, MediaTek and Qualcomm paths only in apps that opted
in (below). A
generic bundle falls back to GPU, then CPU, and prints why; a bundle compiled
for an NPU is refused elsewhere ([Where a model runs](#where-a-model-runs)).
Windows has no device probe: a bundle compiled for the Intel NPU is not refused
on a PC without one, and what LiteRT does then is not measured.

Intel's Gemma 4 12B for Panther Lake needs 1.17.0: its NPU blobs carry metadata
2.7, which the OpenVINO 2026.3 of earlier releases refuses; 1.17.0 ships
OpenVINO 2026.4.1. A bundle whose NPU blobs carry no weights makes the dispatch
copy them to `%TEMP%\litert_ov_bank_<hex>.bin` at every load (5.55 GB for the
12B); from 1.17.0 the next Intel NPU load deletes the banks an exited 1.17.0
app left behind, and banks no app claimed (an older release, the LiteRT-LM CLI)
once the PC has restarted since they were written, and prints how much it
freed. See
[Desktop → Windows NPU](https://flutteredge.ai/docs/desktop).

Run a Gemma 4 bundle on the NPU (none is published for MediaTek: whether its Gemma 3 bundles
keep their chunks is not measured): most Gemma 3 bundles drop every prefill chunk
after the first, with no error, and answer from the start of the prompt alone;
of the published Qualcomm 1B files only `…_sm8850` keeps them
([LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508)).

On macOS, App Nap throttles an app that is in the background: after about a
minute, generation and embedding run several times slower (measured: an
EmbeddingGemma 2 image went from 0.35 s to 2–7 s). An app that embeds or
generates while in the background should hold an activity for the duration —
`ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: …)` in
Swift, ended with `endActivity` when the work is done.

### Where a model runs

Before it creates an engine, the native engine reads the bundle's header and
the compiler stamp of each compiled section (a few hundred bytes each, tens of
milliseconds for a 3 GB file) and decides from them:

| The file | No `preferredBackend` | `preferredBackend` given |
|---|---|---|
| A generic bundle | GPU, then CPU | `gpu` / `cpu`: that backend, then the next; `npu`: not tried, since the bundle has no NPU graph (GPU, then CPU, with a notice; refused with `backendFallback: false`) |
| A text model declaring `backend_constraint` | the first of GPU, CPU it allows | only the backends it declares are tried, the NPU only when the bundle is compiled for one (a file that declares only the NPU and is not is refused) |
| A bundle compiled for an NPU (a `tf_lite_aux` section or a text model with a `LiteRtStamp`, e.g. `…_qualcomm_sm8750.litertlm`) | the NPU | `npu`: the NPU; `gpu`/`cpu`: refused, they cannot run it |
| A file shorter than its sections | refused: the download is incomplete | refused |
| A `.litertlm` the reader cannot read (a newer container version, a malformed header) | GPU, then CPU | the request, then the fallback order, `npu` included: the rules from before the reader |

An encoder you leave unset (`preferredVisionBackend`, `preferredAudioBackend`)
runs where the file says: its declared `backend_constraint` (the CPU when that
allows it), the NPU when its section is compiled for one, else the CPU. So the
official `…_qualcomm_sm8750` and `…_qualcomm_qcs8275` bundles, whose encoders
are not compiled for the NPU, run them on the CPU, and a bundle with compiled
encoders runs them on the NPU, without the app choosing. An encoder runs on the
NPU only together with a text model on the NPU (a bundle compiled for the NPU
throughout): turning on an NPU encoder next to a text model tried on the GPU or
the CPU is refused, and a text-only load of that file runs as on a generic
bundle. Asking an encoder for a backend its `backend_constraint` excludes (the
GPU for the published Gemma 4 and Gemma 3n audio encoders, which declare cpu),
for the NPU when it is not compiled for one, or for another backend when it
is, is refused. The Gemma 3n vision encoder declares gpu only, so it runs on
the GPU by default and `preferredVisionBackend: PreferredBackend.cpu` is
refused for it; the Gemma 4 vision encoder declares nothing and runs on the
CPU.
`InferenceModel.activeVisionBackend` and `activeAudioBackend` report what was
chosen, and are null for a bundle without that encoder.

A refusal is a `LiteRtLmBundleException` with a `problem`
(`incomplete`, `wrongBackend`, `unsupportedNpu` for a text model, or an encoder
the load turns on, compiled for an NPU this package has no dispatch for here —
a bundle of an NPU vendor this package does not know, a Qualcomm bundle on
Windows, or a Google Tensor or MediaTek bundle off Android —
or for an NPU encoder next to a text model that is not on the NPU) and a
message that says
what to do; no engine is created. An NPU bundle, or an encoder the load turns
on that runs on the NPU, on a device whose NPU cannot be reached fails the same
way as a strict load (below), at once, and is never tried on the GPU. The SoC
of the device is not read before the load; a bundle for another Qualcomm SoC
fails at engine create, and the error names the SoC it was compiled for. A file
the header reader does not understand (a `.task` bundle, a newer container)
loads as before.

**Strict backend.** By default a load that fails on its backend tries the next
one. `LiteRtLmEngine(backendFallback: false)` makes exactly one attempt — on
`preferredBackend`, or, when none is given, on the GPU (the NPU for a bundle
compiled for one, the first backend a constrained text model allows) — and
throws a
`BackendInitException` whose one attempt names that backend and carries
LiteRT-LM's own reason (`LiteRtLmEngineCreateException.nativeMessage`, read
from its C API on every platform, release builds included). An NPU the device
cannot reach is refused before any engine exists:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: [const LiteRtLmEngine(backendFallback: false)],
);
try {
  await FlutterEdgeAi.getActiveModel(preferredBackend: PreferredBackend.gpu);
} on BackendInitException catch (e) {
  final error = e.lastAttempt.error;
  print('did not load on ${e.lastAttempt.backend.name}: '
      '${error is LiteRtLmEngineCreateException ? error.nativeMessage : error}');
}
```

Use it when another backend would be wrong rather than slow: a benchmark, an
NPU demo, or an app that would rather say so than load gigabytes again on the
CPU. `activeBackend` names what ran either way. The encoders never fall back.

**Several models at once.** On Android, iOS and desktop `LiteRtLmEngine` is a
`MultiModelEngine` (the web engine is not), so `FlutterEdgeAi.openModel(spec, …)`
(`flutter_edge_ai` 2.5.0) can keep several of its models open, such as one
file on CPU and GPU. Each holds its own weights and KV cache, and the app
closes it. Engine creations run one at a time. Measured on macOS only; see
[Desktop → Several models at once](https://flutteredge.ai/docs/desktop#several-models-at-once).

**Thinking budget.** `LiteRtLmEngine(thinkingTokenBudget: 512)` (1.18.0)
caps how many tokens each generation with `enableThinking: true` spends
thinking, in every model the engine builds, on the CPU, the GPU and the NPU;
null (the default) sets none. At the budget LiteRT-LM closes the thought
channel and the model goes on to the answer or the tool call. Without one, a
model can think until `maxOutputTokens` and end the turn with an empty answer.

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(thinkingTokenBudget: 512)],
);
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final chat = await model.createChat(
  enableThinking: true,
  maxOutputTokens: 2048,
  modelType: ModelType.gemma4,
);
```

- The thinking counts towards `maxOutputTokens`, and the reply, with the
  prompt and the history, towards the context (`maxTokens`, 1024 by default):
  keep the budget below `maxOutputTokens` and below what the context has left,
  with room for the answer, or the budget is never reached.
- It applies only with thinking on. A model that reasons with
  `enableThinking: false` too, such as Qwen3 4B Thinking 2507, is not capped
  then.
- It is per generation: every send with thinking on carries it, so in a tool
  loop a generation after a tool result has its own budget. Gemma 4 E2B did not
  think again after a tool result in the measured runs, so only the first
  generation of such a turn was seen capped.
- LiteRT-LM caps the first channel the bundle declares (measured on Gemma 4 E2B
  and `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`). A bundle that declares none
  is not capped, and loading one with a budget prints a warning.
- It is fixed when the engine is registered. To change it, close the model,
  call `FlutterEdgeAi.reset()` (it drops every registration, not only the
  engine), `initialize` again with every provider the app uses, then install
  and load the model again.
- A value outside 1..0x7fffffff throws `ArgumentError` when a model loads.
- On the GPU it slows decoding for the whole generation, after the budget is
  reached too, by about a fifth on an M5 Pro and about 40% on an NVIDIA L4; on
  the CPU no cost was measured.
- The web engine accepts it and ignores it.

Measured on macOS (M5 Pro), Gemma 4 E2B, greedy, `maxTokens` 2048,
`maxOutputTokens` 1536:

| | CPU | GPU |
|---|---|---|
| Thinking: no budget → budget 64 | 1724 → 198 characters | 1465 → 198 characters |
| Decode: no budget / budget 1200, never reached (same output) | 55.0–55.1 / 55.0–55.7 tok/s | 117.2–118.4 / 87.4–97.2 tok/s |
| A tool turn with thinking on, budget 64 | the call and the answer | the call and the answer |

On Linux (NVIDIA L4), the same test: decode 14.4 tok/s on the CPU either way,
and on the GPU 111 tok/s without a budget, 68 with one it never reached.

`Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` on the CPU: without a budget it
thought for 4507 characters and answered nothing; with a budget of 32 it thought
for 107, then answered.

**Native log level.** `LiteRtLmEngine(nativeLogLevel: LiteRtLmLogLevel.verbose)`
sets the minimum severity of LiteRT-LM's own native log before each engine
is created (`litert_lm_set_min_log_level`). The level is
process-wide; null leaves the level the process has, LiteRT-LM's default until
an engine sets one. `silent` silences LiteRT-LM's library, its absl, LiteRT and TFLite logging included
(upstream `SetMinLogSeverity`); other native libraries keep their own logs (the
GPU accelerator, the NPU dispatch, drivers, the separately loaded `LiteRt`
library). Native platforms only: the web engine accepts it and ignores it.
Above `info`, debug builds lose the INFO lines from which a failed create names
the backend a model requires. On Windows, when the app's output is redirected
(`app.exe 2> err.log`), the lines follow the redirect from 1.17.0; before
that the Flutter runner's `AttachConsole` sent them to the parent's console.

### Inspecting a model file

`readLiteRtLmBundleInfo(path)` returns what the planner reads (native only; it
throws `UnsupportedError` on the web):

```dart
final info = await readLiteRtLmBundleInfo(path);
info.isComplete;               // false for a download that stopped early
info.isCompiledForNpu;         // runs on the NPU only
info.npuTarget;                // e.g. Qualcomm SM8750 / Google Tensor_G5
info.visionEncoder?.npuTarget; // null: the encoder is not compiled
info.audioEncoder?.backendConstraint; // e.g. ['cpu']
info.hasMtpDrafter;            // can decode speculatively
for (final section in info.sections) {
  print('${section.dataType} ${section.modelType} ${section.items}');
}
```

It reads the header and a few hundred bytes per compiled section, never the
weights. A file that is not a `.litertlm` container, of another container
version, or with an unreadable header throws `LiteRtLmBundleException`.

### Google Tensor NPU on Android (opt-in)

A bundle compiled for a Tensor NPU (`…_Google_Tensor_G5.litertlm`,
`…_Google_Tensor_G6.litertlm`; its `LiteRtStamp` names `Google`, the file name
is not read) runs on the NPU of a Pixel with that Tensor generation and Android
16 or later, not a BP2A build: LiteRT's own requirement, checked before any
engine. The load is NPU-only: a device that cannot run it is refused, never
moved to the GPU or the CPU.

The dispatch is opt-in, as Qualcomm's is:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      google_tensor_npu: true
```

With it the build bundles `libLiteRtDispatch_GoogleTensor.so`, which we build
from the pinned LiteRT source (`litert/vendors/google_tensor/dispatch`; Google's
Tensor SDK terms, `TERMS_OF_USE.md` in that directory, cover it besides its
sources' own licence headers). The runtime it drives, `libedgetpu_litert.so`, is
part of the Pixel system image, is never redistributed, and core declares it as
an optional system library. An app can set both opt-ins: the bundle's stamp
picks the vendor, and LiteRT gets a directory with that vendor's libraries only.

Run on a Pixel 11 Pro and a Pixel 11 (Tensor G6) with debug builds: Gemma 4
E2B text, images and audio on the NPU, and EmbeddingGemma 2 270m and 440m (text
and an image). Not run yet: a
Tensor G5 and a release-signed build. On one Pixel the EdgeTPU service logged
that the app is not on its allowlist; that did not stop the debug run.

### MediaTek NPU on Android (opt-in)

A bundle compiled ahead of time for a MediaTek SoC (`…_mt6991.litertlm`,
`…_MediaTek_MT6991.litertlm`; its `LiteRtStamp` names `MediaTek` and the SoC,
the file name is not read) runs on the APU of a phone with that SoC, Android
12 or later: LiteRT's own requirement (a `Mediatek` or `MTK` SoC
manufacturer), checked before any engine, together with whether one of the
phone's NeuroPilot adapters opens in the app. The load is NPU-only: a device
that cannot run it is refused, never moved to the GPU or the CPU. A generic
bundle is not compiled on the device.

The dispatch is opt-in:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      mediatek_npu: true
```

With it the build fetches Google's `litert-npu-runtime-mediatek` 2.3.0 AAR from
Google Maven (checksum-pinned; `mediatek_npu_maven_url` names a mirror,
`mediatek_npu_aar` a downloaded copy) and bundles its
`libLiteRtDispatch_MediaTek.so` (Apache 2.0), about 330 KB, into every Android
arm64 build of the app. It is not in this package's release: building it needs
MediaTek's NeuroPilot SDK, whose licence lets it reach users only inside an
application. The NeuroPilot runtime it drives is part of the phone's system,
is never redistributed, and core declares its libraries as optional; a phone
whose vendor does not expose them to apps is refused with the reason. An app
can set this with the other opt-ins: the bundle's stamp picks the vendor.
The AAR's `LICENSE` and `THIRD_PARTY_NOTICE.txt` stay in the hook's cache (the
build prints where); an app that lists the open-source licences it ships should
add them.

Run on a Galaxy Tab S10+ (Dimensity 9300+, MT6989, Android 16) with a debug
build: Gemma 3 1B (`…_mt6989`) generates on the NPU. Bundles for another SoC
are refused when the engine is created, and nothing else is tried: Gemma 3 1B
`…_mt6991` and EmbeddingGemma 2 270m `…_MT6991` (NeuroPilot: unsupported target
`EDPA_1_2`), EmbeddingGemma 2 440m `…_MT6993` (Neuron SDK major version
mismatch). Qwen3 0.6B `…mediatek.mt6993` fails before the NPU, on its tokenizer
(`piece must not include null character`, LiteRT-LM#3865). Not run yet: a
bundle on an MT6991/MT6993 phone, and a release-signed build. Google publishes
Gemma 3 1B (MT6989, MT6991, MT6993), Gemma 3 270M (MT6991, MT6993), Qwen3 0.6B (MT6993) and EmbeddingGemma 2
(MT6991, MT6993) bundles; Gemma 4 has none.

### Qualcomm NPU on Android and Linux arm64 (opt-in)

This package does not ship Qualcomm's QNN runtime: Qualcomm licenses it for
redistribution inside an application only. To use `PreferredBackend.npu` on
Snapdragon, opt in from your app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

Put it in the pubspec of the app you build. If that app is a member of a pub
workspace, put it in the workspace root's pubspec instead; pub ignores
`user_defines` anywhere else.

With the flag set, the build hook downloads `com.qualcomm.qti:qnn-runtime:2.50.0`
from Maven Central once, checks its SHA-256, raises the Hexagon libraries'
page alignment to the 16 KB Google Play requires, and bundles the ten QNN
libraries into the Android app: about 22 MB more to download and 83 MB more
installed (one blob per Hexagon generation, V73 to V81). The first NPU run
copies them out of the APK once more, because the DSP loads them from files,
so a phone that uses the NPU holds about 166 MB of them. Setting the
flag means accepting Qualcomm's AI Stack License, the `LICENSE.pdf` the hook
prints the path of. Its notices are in this package's `NOTICES`, so they reach
your app's licence page.

Behind a proxy, the hook honours `HTTPS_PROXY`. Without access to Maven Central,
point it at a mirror or at the AAR itself:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
      qualcomm_npu_maven_url: https://maven.example.com/maven2
      # or: qualcomm_npu_aar: third_party/qnn-runtime-2.50.0.aar
```

`qualcomm_npu_aar` is resolved against the pubspec that declares it and must be
the same file as Maven's (same SHA-256). Without the flag, a bundle compiled for
an NPU is refused with a `BackendInitException` whose one attempt says how to
enable it ([Where a model runs](#where-a-model-runs)). A generic bundle never
runs on the NPU, with or without the flag: it has no NPU graph, and LiteRT
would try to compile it on the device with a compiler plugin, which no NPU stack
here ships, and run it on the CPU while reporting `npu` (measured on a Galaxy
S24). So `npu` falls back to
GPU, then CPU, for it, and the log says why.

**Linux arm64.** The same flag bundles the stack into Linux arm64 builds, for
Qualcomm Linux boards with a Hexagon V68–V81 compute DSP (QCS6490, QCS8275,
QCS9075, …). Qualcomm publishes no Maven artifact for Linux, so the hook reads
the fourteen libraries it needs (libQnnHtp, libQnnSystem and a Stub/Skel pair
per Hexagon version) out of Qualcomm's public QAIRT 2.50 SDK zip with HTTP range
requests — about 32 MB of a 2.6 GB archive — checks each against a pinned
SHA-256, and caches them; about 90 MB more installed. Offline, download
`v2.50.0.260828.zip` yourself and point the hook at it:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
      qualcomm_npu_qairt_zip: third_party/v2.50.0.260828.zip
```

On the board, Qualcomm's FastRPC library must be installed (`qcom-fastrpc1` on
Ubuntu; Qualcomm's images ship it) and the user must be in group `fastrpc`
(`sudo usermod -aG fastrpc $USER`, then log in again). If either is missing, a
bundle compiled for an NPU is refused with a `BackendInitException` that names
what to fix. Use the model compiled for your SoC, e.g.
`gemma-4-E2B-it_qualcomm_qcs8275.litertlm`. A Linux x64 build ignores the
flag.

**Embeddings.** The same flag runs EmbeddingGemma 2 per-SoC bundles on the NPU
([EmbeddingGemma 2 on a Qualcomm NPU](#embeddinggemma-2-on-a-qualcomm-npu));
Windows runs the Intel ones without it
([EmbeddingGemma 2 on an Intel NPU](#embeddinggemma-2-on-an-intel-npu-windows)).
Unlike the LLM path, an embedder never falls back: when the NPU cannot run the
bundle, `getActiveEmbedder` fails with `EmbeddingLoadException` and the reason,
because CPU vectors would land in another space.

## Troubleshooting

### Windows ARM64: LiteRT-LM inference is not available

Symptom: a native Windows ARM64 build (a Snapdragon X laptop) succeeds, then
the first `.litertlm` model fails with `Failed to load dynamic library
'StreamProxy.dll'` (error 126). The build hook now prints why while it builds.

Cause: there is no `windows_arm64` LiteRT-LM archive. Upstream does not build
LiteRT-LM for Windows ARM64, so there is nothing to package. The hook skips the
target instead of failing, so an app that uses another engine still builds.

What works today: MediaPipe has no desktop engine. The ONNX engine
(`flutter_edge_ai_onnx`, ONNX models, not `.litertlm`) bundles Windows ARM64
archives and passed generation and embedding smoke tests on a Windows 11 ARM64
runner. The other option is to
build the app for x64, which runs under Windows x64 emulation. See
[#326](https://github.com/DenisovAV/flutter_edge_ai/issues/326).

### FunctionGemma answers with nothing, or only `<pad>`, on the GPU

Symptom: a FunctionGemma `.litertlm` on `PreferredBackend.gpu` loads, reports
`gpu`, and then every prompt returns no text and no call (or `<pad>` to the
token limit), with no exception and no warning. On the CPU the same file works.

Cause: the bundle was converted before litetune 0.1.4 and declares no
`prefer_activation_type`, so the GPU runs at FP16, which these weights cannot
survive. It is the file, not the platform: Android (Adreno and Mali) and macOS
Metal are reported, and an Adreno 616 reproduced it. A bundle that declares the
key, such as Gemma 4, is not affected.

Fix: nothing, for `ModelType.functionGemma` on native platforms (the web build
has no activation setting). The engine reads the bundle's header and, when it
declares no `prefer_activation_type`, builds the GPU attempt at
`ActivationDataType.float32`; the log line saying so is printed in debug builds
only. The CPU is left alone, and so is a value you pass:
`activationDataType: ActivationDataType.float16` keeps the default.

Other models are not changed, and some need the argument. A plain
`gemma3-270m-it` floods `<pad>` on the GPU too (every Gemma 3 270M bundle does,
on macOS and Android: LiteRT-LM#3280) and needs
`activationDataType: ActivationDataType.float32` passed explicitly: it is
`ModelType.gemmaIt`, which the automatic float32 above does not cover. The
larger Gemma bundles (Gemma 3 1B, Gemma 4) are not affected.

### Wrong digits from a long prompt on GPU

Gemma 4 can copy numbers wrongly out of a prompt of about 2,000 tokens or more
on Metal and Adreno, the same way on every run. The published Gemma 4
`.litertlm` files ask for half-precision activations; pass
`activationDataType: ActivationDataType.float32` to `getActiveModel` for full
precision.

### `Qwen3-0.6B.litertlm` fails to load

Symptom: the engine fails to create for `Qwen3-0.6B.litertlm` from
[litert-community/Qwen3-0.6B](https://huggingface.co/litert-community/Qwen3-0.6B),
with `piece must not include null character` in the native error.

Cause: the SentencePiece version in LiteRT-LM since v0.17.0 (this package's
1.7.0) rejects one piece of that bundle's old tokenizer
([LiteRT-LM #3865](https://github.com/google-ai-edge/LiteRT-LM/issues/3865)).
On 2026-10-13 at 15:53 UTC the repository replaced the tokenizer
([e6687177](https://huggingface.co/litert-community/Qwen3-0.6B/commit/e6687177)); the file downloaded since loads (measured on macOS with
1.15.0). A copy downloaded earlier keeps the old tokenizer under the same name.

Fix: uninstall the model and install it again, or install
`Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` from the same repository (measured
working on `native-v0.18.0-e`). See [#659](https://github.com/DenisovAV/flutter_edge_ai/issues/659).

### Linux: any tool call aborts the app (fixed in 1.11.1)

Up to 1.11.0, a chat or session with `tools` aborted on its first constrained
token on Linux x64 and arm64: the prebuilt constraint provider uses another C++
ABI than the runtime. 1.11.1 (`native-v0.18.0-d`) bridges it. See
[#551](https://github.com/DenisovAV/flutter_edge_ai/issues/551).

### iOS/macOS: GPU crashes in apps that also use `flutter_litert` (fixed in 1.10.1)

In 1.10.0 the GPU backend crashed in `LiteRtCreateCompiledModel` when the app
also used `flutter_litert`. 1.10.1 (`native-v0.18.0-b`) fixes it; no app change
is needed.

### Qwen keeps reasoning with thinking off, or shows `<|channel>thought` text (fixed in 1.9.0)

Up to 1.8.7 "thinking off" sent nothing to the template, and a Qwen3 template
that reads `enable_thinking` treats a missing key as on: a bundle such as
`Qwen3-0.6B_dynamic` spent its whole output budget reasoning. Bundles that
declare a thought channel also streamed that reasoning into the answer as
`<|channel>thought…<channel|>` text, and the web path sent `thinking` — a key no
template reads. 1.9.0 sends `enable_thinking` both ways on every platform, and
`flutter_edge_ai` 2.1.0 turns channel reasoning into `ThinkingResponse` for every
`ModelType` and no longer appends ` /no_think` to an audio message (Qwen3-ASR
returned an empty transcript).

### A stopped chat answers every later message with nothing (fixed in `flutter_gemma_litertlm` 1.8.1)

Symptom: after `stopGeneration()` in the middle of a reply — or after
abandoning the response stream — every later message on that chat or session
comes back empty, on Android, iOS and desktop. A new chat on the same model
answers normally. (The web engine is a separate path and is not covered by this
entry.)

Cause: a conversation whose generation is cancelled mid-reply stays unusable
in the native runtime.

Fix: every `flutter_edge_ai_litertlm` release answers again after a stop.
Since 1.15.0, releases rewind the conversation to before the stopped turn and
put that turn back: the message, with its images and audio, and whatever the
reply had produced, so the model keeps the whole chat, media included. This
works the same whether the app called `stopGeneration()` or cancelled its
subscription to the reply. 1.14.0 and earlier, and the NPU in every release
(its executor cannot rewind), run the next turn instead on a fresh conversation
that replays the history as text, so images and audio from earlier turns are
gone; send them again if the next question is about them. 1.15.0 and later
also fall back to that replay when a rewind fails, and say so in the log
(release builds too).

### Google Play rejects the app over 16 KB page sizes (fixed in `flutter_gemma_litertlm` 1.8.0)

Symptom: Play Console refuses the release with *"Your app does not support
16 KB memory page sizes"*, on any app that depends on this package. Nothing
fails at build or run time — the rejection happens at submission.

Cause: the Qualcomm Hexagon DSP blobs of the NPU path
(`libQnnHtpV{73,75,79,81}Skel.so`) arrive from Qualcomm with a 4 KB `p_align`.
Before 1.10.0 this package bundled them into every APK; Play scans
`lib/**/*.so` and does not care that a Hexagon image is loaded by the DSP
rather than mapped by the kernel.

Fix: every `flutter_edge_ai_litertlm` release has it. Since 1.10.0 the Skels
ship only when the app sets `qualcomm_npu: true`, and the hook raises them to
16 KB. Check your own build with Google's `check_elf_alignment.sh` against the
APK, not against this package.

### Android GPU crashes at engine_create on Mali (fixed in `flutter_gemma_litertlm` 1.8.2)

Symptom: in `flutter_gemma_litertlm` 1.7.0–1.8.1, `PreferredBackend.gpu` on an Android phone with a Mali
GPU (Samsung A-series, MediaTek, Google Tensor) kills the process while the
model loads — `SIGSEGV` at `pc 0` inside `libLiteRtOpenClAccelerator.so`. The
CPU backend and Adreno GPUs are unaffected.

Cause: the OpenCL and GPU accelerators from LiteRT-LM v0.17.0 call
`AHardwareBuffer_allocate` without declaring `libandroid.so` as a dependency, so
Android binds the call to address 0. Only Mali takes that path.

Fix: every `flutter_edge_ai_litertlm` release has it; no app change is needed. See
[#545](https://github.com/DenisovAV/flutter_edge_ai/issues/545).

### Any tool call kills the app (fixed in `flutter_gemma_litertlm` 1.7.1)

Symptom: in `flutter_gemma_litertlm` 1.7.0, a chat or session created with
`tools` dies on the first decoded token — `EXC_BAD_ACCESS` / `SIGSEGV` inside
the runtime, on every platform, CPU and GPU alike (Linux had a second cause,
fixed in 1.11.1 — see above). Dart sees no exception; `flutter test` reports only
that the test did not complete. Generation without tools is unaffected.

Cause: constrained decoding is implemented by a prebuilt companion,
`libGemmaModelConstraintProvider`, that ships with the LiteRT-LM release.
Upstream replaced the `Constraint` interface, and the companion published at tag
v0.17.0 still implements the old one, so the runtime we build calls into the
wrong vtable slot.

Fix: every `flutter_edge_ai_litertlm` release has it: since
`flutter_gemma_litertlm` 1.7.1 the companion is rebuilt from upstream main.

### Windows: embeddings or speech fail with `status=3` (fixed in `flutter_gemma_litertlm` 1.7.0)

Symptom: on Windows only, `LiteRtEmbeddingBackend` and `flutter_edge_ai_speech`
fail with `LiteRT call failed: CreateTensorBufferFromHostMemory(...) (status=3)`
in `flutter_gemma_litertlm` 1.4.0–1.6.4. Text generation is unaffected.

Cause: LiteRT made `LiteRtLayout` one layout on every compiler; this package
still wrote tensor shapes in the old MSVC layout on Windows.

Every `flutter_edge_ai_litertlm` release includes the fix. On the legacy package
line, upgrade `flutter_gemma_litertlm` to 1.7.0 and `flutter_gemma_speech` to
0.5.1.

### Garbled or empty streams on Android (fixed in `flutter_gemma_litertlm` 1.5.2)

Symptom: a generation delivers zero chunks and throws
`Exception: Stream error: <U+FFFD>`, often followed by
`Callback invoked after it has been deleted` and a `SIGABRT` that Dart cannot
catch.

Cause: on Android the first `dlopen` of `libLiteRtLm` decides, for the whole
process, whether its exports are reachable from the default symbol search
scope, and bionic never promotes an already-loaded library afterwards. Before
`flutter_gemma_litertlm` 1.5.2 the embeddings and speech entry point opened it
locally, so an app that embedded or transcribed anything before its first
generation left the
stream-callback ABI probe unable to see the library — and the probe read that
as "old library" and registered the wrong callback shape.

Fix: every `flutter_edge_ai_litertlm` release has it. If you load `libLiteRtLm`
yourself from app or third-party code, load it before flutter_edge_ai does and
with `RTLD_GLOBAL`. The package cannot repair that case — bionic never promotes
an already-loaded library — but it no longer generates corrupt text: a `.litertlm` generation raises a
`StateError` naming the condition, and embeddings or speech (which resolve
through their own handle and do not need the symbols to be ambient) log a
warning and carry on.
See [#447](https://github.com/DenisovAV/flutter_edge_ai/issues/447).

### `dlopen` / "library not found" (`libLiteRtLm`)

`flutter_edge_ai_litertlm` is the sole owner of the shared native library
(`libLiteRtLm`) and bundles it via its build hook — this package's own
`LiteRtEmbeddingBackend` and `flutter_edge_ai_speech` both use it directly. A
stale Native-Assets cache after a
native version bump can leave the library unbundled, surfacing as an opaque
`dlopen` "no such file" on the first inference. Fix with a clean rebuild:

```bash
flutter clean
rm -rf ~/Library/Caches/flutter_gemma/native        # macOS
rm -rf ~/.cache/flutter_gemma/native                # Linux
# Windows: rmdir /s /q "%LOCALAPPDATA%\flutter_gemma\native"
flutter pub get
```
