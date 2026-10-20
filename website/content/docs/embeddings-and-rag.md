---
title: Embeddings & RAG
description: Embed text, images and audio with EmbeddingGemma 2, EmbeddingGemma 1, Gecko or ONNX models across nine task types, and build profile-safe on-device RAG with pluggable SQLite or Qdrant storage.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Flutter Edge AI separates three concerns:

- **flutter_edge_ai** installs and runs embedding models.
- **flutter_edge_ai_rag** owns instance-scoped retrieval orchestration, stable
  embedding profiles, filters, and **RagIndex**.
- **flutter_edge_ai_sqlite** and **flutter_edge_ai_qdrant** provide
  interchangeable vector stores.

RAG can borrow the active core embedder, use an application-provided
**RagEmbedder**, or run entirely on precomputed vectors. It does not require an
inference model and is not initialized through **FlutterEdgeAi.initialize()**.

## Custom embedding providers (core 2.5.0)

Core accepts self-contained `.gguf` files without a separate tokenizer. When
backends are registered, installation checks that one can serve the file; with
none registered, installation can still proceed. No GGUF embedding backend ships
yet; executing these files requires a supporting engine package.
`flutter_edge_ai_embeddings` supplies tokenizers; engine packages own runtime
passes, and core hosts, caches and closes those passes.

Backend authors declare supported explicit requests through
`EmbeddingBackendProvider.honouredBackends(spec)`. Core computes cache identity:
automatic requests reuse only a non-NPU embedder for the same installed model,
explicit NPU requests retain their own key, and automatic builds of GPU-capable
providers are recorded under the loaded accelerator. GPU-capable providers must
report it through `EmbeddingPassInfo.activeBackend`; a descriptor alone is not
proof of placement. Existing providers retain their fixed descriptor fallback.
Repeated explicit CPU/GPU requests reuse their originating model, including a
fallback, until a rebuild is needed or it is closed. Reporting providers print
one release-visible WARNING per new fallback load, including an NPU request;
reuse does not repeat it.
`EmbeddingModel.maxInputTokens` is the effective loaded context/single-pass batch
limit, including task prefixes and special tokens; null means unknown, not
unlimited. A GGUF pass configured with a 1024-token micro-batch cannot accept a
larger chunk just because the model file declares a larger context.

## Packages

```
dependencies:
  flutter_edge_ai: ^2.5.0
  flutter_edge_ai_litertlm: ^1.16.0
  flutter_edge_ai_embeddings: ^2.3.2 # tokenizers for .tflite / .onnx models
  flutter_edge_ai_rag: ^1.1.2
  flutter_edge_ai_sqlite: ^2.1.1 # all six platforms, including Web
  # flutter_edge_ai_qdrant: ^2.1.1 # native alternative
```

<Warning>

Upgrade every flutter_edge_ai package together. With core 2.3.0 the minimum
versions are litertlm 1.13.0, embeddings 2.3.0, onnx 0.5.8, rag 1.1.0, sqlite
and qdrant 2.1.0 (the full list is in [Migration](/docs/migration)). An older
engine or store fails to compile against 2.3.0.

</Warning>

**flutter_edge_ai_sqlite** needs Flutter 3.47 or later. On Web, `.tflite`
embeddings and SQLite RAG need files copied into your app's **web/** — the
LiteRT.js loader and **rag/sqlite3.wasm**; EmbeddingGemma 2 needs only the
`@litert-lm/core` module script, with its **window.EmbeddingEngine** line, in
`web/index.html`; see
[Installation → Web](/docs/installation#web).

## Embedding models

| Model | Files | Platforms | Tokenizer | Longest input |
|---|---|---|---|---|
| EmbeddingGemma 2 (text, images, audio) | one `.litertlm` | Android, iOS, macOS, Linux, Windows; Web on WebGPU; per-SoC bundles on Qualcomm NPUs, on Google Tensor G5/G6 (Android, opt-in; G5 not run) and on Intel Panther Lake NPUs on Windows (not run) | inside the bundle | 1024 tokens |
| EmbeddingGemma 1, Gecko | `.tflite` + tokenizer file | Android, iOS, macOS, Linux, Windows, Web | `flutter_edge_ai_embeddings` | the model's sequence length |
| MiniLM, EmbeddingGemma ONNX | `.onnx` + `tokenizer.json` | native via **flutter_edge_ai_onnx**; Web for WordPiece models | `flutter_edge_ai_embeddings` | the graph's static length, or none |

The first two run on **LiteRtEmbeddingBackend** from **flutter_edge_ai_litertlm**;
the ONNX ones on **OnnxEmbeddingBackend** from **flutter_edge_ai_onnx**. LiteRT
EmbeddingGemma (1 and 2) and Gecko produce 768-dimensional vectors;
all-MiniLM-L6-v2 produces 384. A number such as 256 in an artifact name is the
maximum input length in tokens, not the vector dimension. See
[Models](/docs/models#embedding-models) for download links.

## EmbeddingGemma 2

EmbeddingGemma 2 ships as one `.litertlm` bundle that carries its own
tokenizer: install the model alone — no **tokenizerFrom…()** call, and no
**flutter_edge_ai_embeddings** or **embeddingTokenizers:** needed. The
text-only 270m bundle is the one for text; the 440m adds images
([below](#embeddinggemma-2-images)) and the 740m adds audio
([below](#embeddinggemma-2-audio-and-combined-inputs)). The repositories are
not gated.

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
  EmbeddingInput.text('Flutter runs on six platforms.'),
  taskType: TaskType.retrievalDocument,
);
```

- **Every platform**: Android, iOS, macOS, Linux and Windows
  (flutter_edge_ai_litertlm 1.13.0 for text, 1.13.1 for images and audio),
  and the Web (1.13.1 for text and images, 1.13.2 for audio and combined
  inputs), where it runs through `@litert-lm/core`'s EmbeddingEngine on
  WebGPU and needs **window.EmbeddingEngine = m.EmbeddingEngine;** in
  `web/index.html` ([Installation](/docs/installation#web)).
- **Text on every bundle, images on the 440m and the 740m, audio on the
  740m.** On the 270m, **getActiveEmbedder(supportImage: true)** throws
  **EmbeddingLoadException** naming the 440m bundle — natively from the
  bundle's model info before any engine or cache is made; on the Web the
  engine create refuses it, and the message suggests the 440m.
  On the 270m and the 440m **supportAudio: true** throws naming the 740m —
  read from the bundle's own header before any engine or cache is made, on
  the Web too.
- **At most 1024 tokens per input**, task prefix, BOS and EOS included
  (**maxInputTokens** is 1024). Keep chunks at 512 tokens or fewer: memory
  grows with the input length — on an M4 Pro Mac about +170 MB at 128 tokens,
  +340 MB at 512 and +560 MB at 1024. A longer input throws
  **EmbeddingInputTooLongException** with the exact **actualTokens** (natively
  from litertlm 1.13.1). The engine counts it by running the whole input, so
  an over-long input costs one full embedding before it is refused.
- **CPU natively, WebGPU on the Web.** **activeBackend** is
  **PreferredBackend.cpu** natively and **PreferredBackend.gpu** on the Web.
  The NPU runs the per-SoC bundles
  ([below](#embeddinggemma-2-on-a-qualcomm-npu)); this bundle refuses
  **PreferredBackend.npu**. The Web has no CPU path for these bundles — the
  CPU (WebAssembly) backend of `@litert-lm/core` 0.18.0 cannot read their
  external weights — so a browser without WebGPU (no **navigator.gpu**, or no
  GPU adapter) throws **EmbeddingLoadException** saying so before anything
  loads. Web vectors come from WebGPU and differ slightly from the native CPU
  ones (measured min cos about 0.995 for text, 0.998 for images); retrieval
  across platforms holds — web text queries find natively embedded images and
  native queries find web-embedded images, top-1 10/10 on the example's ten
  scenes.
- **Disk:** the 165 MB bundle plus a 71 MB weight cache the engine writes at
  its first load (the 440m bundle adds 218 MB for vision, the 740m bundle
  writes 385 MB in total, even for text-only use). The cache lives in the app's
  cache directory: never backed up, and rebuilt at the next load if the OS
  clears it. The engine opens one cache file per tower when it loads; when it
  cannot create one (a path too long for the platform, such as past Windows'
  260-character MAX_PATH, a directory the app cannot write to, or possibly no
  free space at all) that tower runs anyway, slower to load and, measured on
  the 270m, with about 290 MB more memory, and the package only prints a
  warning. A disk that fills while the cache is being written ends the
  process instead: the engine (XNNPack) aborts in native code, and no flag can
  catch that. The Web keeps no weight cache: the bundle sits in the browser's
  storage.
- **requireWeightCache (flutter_edge_ai_litertlm 1.14.0).** Register
  **LiteRtEmbeddingBackend(requireWeightCache: true)** to make a load that
  wrote no weight cache a failure: **getActiveEmbedder()** throws
  **EmbeddingLoadException** naming the cache directory, the length of the
  cache file path and the likely causes, and no engine is left running. One
  tower's cache missing beside the others stays a printed warning. It applies
  on CPU, and on the NPU only with declared audio, whose tower runs on CPU;
  the Web and a **.tflite** embedder (EmbeddingGemma 1, Gecko) accept it and
  ignore it, and a debug build says so once in the log. The warning is a **print**, which a
  Windows release build started from Explorer shows nowhere (it has no
  console): Windows desktop apps that care should pass
  **requireWeightCache: true**. A refusal comes after core has closed the
  embedder it held, and the RAG **FlutterEdgeAiActiveEmbedder** re-resolves
  the model for every operation, so each call repeats the engine create
  before it refuses.
- EmbeddingGemma 1 and 2 are different embedding spaces with the same
  dimension: give each its own vector-store location and profile.

### EmbeddingGemma 2 images

The 440m bundle has the 270m's text tower (the same text vectors) plus a vision
encoder, so one model embeds text and photos, and a text finds photos. It needs
flutter_edge_ai_litertlm 1.13.1, on the Web too. Declare images when you get
the embedder, and keep the photos in an image index:

```dart
const visionRevision = 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8';
// The text profile id plus the vision budget: image vectors depend on it.
const photosProfileId =
    'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-vis140';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-vision-440m-litert-lm/resolve/$visionRevision/'
      'embeddinggemma-2-text-vision-440m.litertlm',
    )
    .install();

final rag = FlutterEdgeAiRag(providers: const [SqliteVectorStoreProvider()]);
final photos = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: photosDbPath,
    documents: EmbeddingModality.image,
  ),
  embedder: FlutterEdgeAiActiveEmbedder(
    profileId: photosProfileId,
    supportImage: true,
  ),
);
await photos.add(
  id: 'photo-1',
  document: EmbeddingInput.image(await uprightAndSmall(photoBytes)), // below
  content: photoPath, // a reference to the photo, never its bytes
);
final hits = await photos.search(query: EmbeddingInput.text('a red bicycle'));
```

**Pass upright, downscaled images.** The engine decodes the file itself and
ignores EXIF orientation, so a portrait photo from a phone camera — stored
sideways with an orientation tag — is embedded lying on its side (measured: cos
0.89 against the same picture upright). It also decodes at full size, which a
12 MP photo pays for in time and memory. Decode with Flutter first: it applies
the orientation and decodes straight to the target size.

```dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// [photo] upright and at most 1024 px on its long side, as PNG.
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

This also converts what Flutter decodes and the engine does not (WebP; HEIC on
Android). Keep the original for display; give the model the result. The
example app writes BMP instead of PNG, which is cheaper. The same code runs on
the Web, where the browser decodes (CanvasKit or skwasm) on the page itself.

- **Formats the engine decodes:** JPEG, PNG, GIF and BMP. HEIC, WebP, TIFF and
  AVIF throw **EmbeddingFormatNotSupportedException** (naming the detected and
  the accepted formats) before anything is sent: decode them as above. A
  corrupt or truncated file of an accepted type throws
  **EmbeddingEngineException** (native code 3; on the Web the message carries
  the runtime's reason) and the embedder keeps working.
  One image per vector, unless you send several as one combined input
  (natively from litertlm 1.13.1, on the Web from 1.13.2;
  [below](#embeddinggemma-2-audio-and-combined-inputs)).
- **Vision budget:** 140 tokens per image by default, the closest to the
  reference model (min cos 0.985 on our test images).
  **LiteRtEmbeddingBackend(visionTokensPerImage: 70)** — what the model card
  and Google AI Edge Gallery use — is about twice as fast with slightly lower
  fidelity (min cos 0.970). Any other value throws **EmbeddingLoadException**.
  Text vectors do not depend on it; image stores do, so their profile id names
  it (`-vis140`, `-vis70`).
- **On the Web, not next to an LLM:** the page's `@litert-lm/core` module has
  4 GB of WebAssembly memory, and the vision encoder does not fit in it next
  to Gemma 4 E2B (measured) — **getActiveEmbedder(supportImage: true)** then
  throws **EmbeddingLoadException** saying to close the LLM first. Text-only
  embedding loads next to the LLM. On WebGPU an image takes about 0.33 s
  (Tesla T4).
- **Cost** (CPU, measured): a 388 MB bundle; a 218 MB vision weight cache
  written at every load, next to the 71 MB text cache in the app's cache
  directory, also when you embed only text. The first image adds about 385 MB
  of RAM on an M4 Pro Mac and about 500 MB on a Pixel 8. Per image at 140
  tokens: about 0.35 s on an Apple-silicon Mac, about 2 s on an Android
  flagship (Pixel 8 Pro 1.8 s, Pixel 8a 2.3 s), more on mid-range phones and
  rising under sustained load; 70 tokens takes about half. LiteRT-LM's thread
  setting reaches the text tower only. A 440m loaded for text alone still
  loads its vision tower: for text use the 270m.
- A text query over an image index is sent raw (**TaskType.none**): measured,
  the retrieval-query prefix finds the same photos with a smaller margin.
- The example app's **Image Search** screen does all of this with photos from
  the gallery or ten bundled sample pictures.

### EmbeddingGemma 2 audio and combined inputs

The 740m bundle has the 440m's text and vision towers (the same text and image
vectors) plus an audio encoder: a text finds a spoken sentence or a sound, and
one vector can hold several parts — a photo with its caption, a clip with a
note. Native platforms from **flutter_edge_ai_litertlm** 1.13.1, the Web
(WebGPU) from 1.13.2; combined inputs need **flutter_edge_ai** 2.3.1.

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

// Several parts in one vector:
final note = await embedder.embed(
  EmbeddingInput(text: 'kitchen', audio: wavBytes),
  taskType: TaskType.retrievalDocument,
);
```

- **Formats:** WAV, MP3 and FLAC at any sample rate and channel count — the
  engine mixes down to mono and resamples to 16 kHz. Ogg and M4A throw
  **EmbeddingFormatNotSupportedException** before anything is sent; a corrupt
  file of an accepted type throws **EmbeddingEngineException** (native code 2;
  on the Web the runtime's message) and the embedder keeps working. One clip
  per vector.
- **Length:** about 25 tokens per second of audio, so up to about 40 seconds
  fit the 1024-token cap; a 60-second clip throws
  **EmbeddingInputTooLongException** with **actualTokens** 1504, on the Web
  too.
- **Combined inputs:** **EmbeddingInput(text:, images:, audio:)** puts the
  text (with its task prefix), then the images, then the audio into one
  vector, in that order; several images in one input are a combined input
  too. Declare every medium you send (**supportImage: true,
  supportAudio: true**); the cap counts all parts (about 140 tokens per
  image).
- **Cost** (CPU, M4 Pro Mac): a 485 MB bundle and 385 MB of weight caches
  written at every load (text 71 MB, vision 218 MB, audio 95 MB), also for
  text-only use; about 0.2–0.3 s per 3-second clip. On the Web (WebGPU,
  Tesla T4): about 0.3 s per 3-second clip after a first one of about 4 s,
  and no weight cache. For text use the 270m, for text and images the 440m.
- **Audio vectors are not bit-portable.** The audio encoder quantizes its
  activations to 8 bits, so another CPU kernel's last bit, or one sample
  changed by 1, can move a clip's vector by up to cos 0.05; text and image
  vectors do not move that way. What holds across builds is retrieval: in our
  test set every spoken sentence is found by its text query, natively, with
  Google's Python wheel and on the Web, whose audio vectors are within cos
  0.97 of the native ones.
- An audio index keeps the text profile id (audio vectors do not depend on the
  vision budget); a text query over it is sent raw (**TaskType.none**).

### EmbeddingGemma 2 on a Qualcomm NPU

Google publishes each EmbeddingGemma 2 bundle again, compiled for one SoC's
NPU, in the same repositories: `embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm`,
`embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm` and so on.
flutter_edge_ai_litertlm 1.13.1 runs them on **Qualcomm Android (arm64) and
Qualcomm Linux arm64**:

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
print(embedder.activeBackend); // PreferredBackend.npu
```

- **The app opts in to Qualcomm's stack** with the flag the LLM NPU path uses,
  **qualcomm_npu: true** under **hooks: user_defines: flutter_edge_ai_litertlm:**
  ([LiteRT-LM](/docs/litertlm)).
- **Use the bundle for the device's SoC.** Run on device: SM8850 (Snapdragon 8
  Elite Gen 5), SM8650 (Snapdragon 8 Gen 3) and QCS8275 (Arduino VENTUNO Q).
  Google also publishes SM8550, SM8750, Google Tensor G5/G6, MediaTek
  MT6991/MT6993 and Intel PTL builds: the Qualcomm ones load but have not been
  run by us, Tensor G6 runs on a Pixel 11 and G5 is not run
  ([below](#embeddinggemma-2-on-a-google-tensor-npu)), Intel PTL loads on
  Windows x64 but is not run on an Intel NPU
  ([below](#embeddinggemma-2-on-an-intel-npu)), and MediaTek is refused. Every
  build and where it has been run: the [Model Registry](/docs/registry). The
  package reads what a bundle is compiled for from the bundle, not from its
  file name.
- **Fast, and close to the CPU vectors, not equal to them.** On an SM8650
  (Galaxy S24): about 9 ms per text (53 ms on its CPU), 0.31 s per image, 0.85 s
  to load the 270m. Cosine against the CPU bundle: 0.79–0.86 for sentences of a
  few words, 0.92 at about 50 words, 0.99 from about 200; images 0.86–0.88.
  Within the NPU's own space retrieval holds: ten of ten captions find their
  picture, every query its document.
- **Nothing switches backend.** NPU and CPU vectors are not interchangeable,
  so each mismatch throws **EmbeddingLoadException** with what to do instead:
  a per-SoC bundle without **npu**; the generic bundle with **npu**; **npu** on
  iOS, macOS, Linux x64 or the Web; a Qualcomm bundle on Windows; an app built
  without **qualcomm_npu**; no reachable Qualcomm NPU on the device; a bundle
  the NPU cannot run (another SoC's — the load embeds one test text to find
  out). A loaded embedder is never handed to a request for the other backend.
- **An NPU index has its own profile id.** The example app uses the CPU text id
  plus **-npu-&lt;soc&gt;**
  (**embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850**, and
  **…-vis140** for an image index); the 270m and the 440m of one SoC share it,
  their text towers being byte-identical.
  **FlutterEdgeAiActiveEmbedder.forActiveModel** keys on the installed file
  name, so it keeps them apart by itself.
- Text up to 1024 tokens, images on the 440m, as on CPU; audio on the 740m
  per-SoC bundles from 1.13.2, with their audio encoder on the CPU (verified on
  SM8850, Galaxy S26+).

### EmbeddingGemma 2 on a Google Tensor NPU

Google's `…_Google_Tensor_G5.litertlm` and `…_Google_Tensor_G6.litertlm`
bundles (270m, 440m, 740m) load from flutter_edge_ai_litertlm 1.15.0 on a **Pixel with
that Tensor generation and Android 16 or later** (not a BP2A build), with
**PreferredBackend.npu**, in an app whose pubspec sets **google_tensor_npu:
true** under **hooks: user_defines: flutter_edge_ai_litertlm:**
([LiteRT-LM](/docs/litertlm)). Install the bundle from its model's repository at
the revision the [Model Registry](/docs/registry) pins (each size has its own),
and load it as above.

- Run on a Pixel 11 (Tensor G6) with a debug build: the 270m embeds text and
  the 440m images on the NPU. A Tensor G5, the 740m and a release-signed build
  are not run yet.
- The same rules as on Qualcomm: refused without **npu**, off Android, without
  the flag, or on a device outside LiteRT's rule; LiteRT refuses the other
  Tensor generation's bundle when the engine is created. Never moved to CPU.
- **Its own profile id**: the CPU text id plus **-npu-tensor_g6** (and
  **…-vis140** for an image index), shared by the 270m, the 440m and the 740m,
  whose text towers are byte-identical.

### EmbeddingGemma 2 on an Intel NPU

Google's `…_Intel_PTL.litertlm` bundles are compiled for the Intel Panther Lake
NPU. From flutter_edge_ai_litertlm 1.13.2 they load on **Windows x64** (not
yet run on an Intel NPU) with
**PreferredBackend.npu**, through the Intel stack (**LiteRtDispatch.dll**,
OpenVINO and TBB) that every Windows x64 build already carries beside the
executable — no opt-in flag. Install
`embeddinggemma-2-text-270m_Intel_PTL.litertlm` (or the 440m's or the 740m's,
each from its own repository at the revision the [Model Registry](/docs/registry)
pins), and load it as above.

- **The load checks the NPU.** It embeds one test text and refuses unless it
  gets a valid vector, so a PC without an Intel NPU, or one the stack cannot
  drive, gets **EmbeddingLoadException** rather than wrong vectors.
- The same rules as on Qualcomm: refused without **npu**, refused on any other
  platform (an Intel bundle on Android or Linux, a Qualcomm one on Windows),
  refused with the reason when **LiteRtDispatch.dll** is not beside the
  executable, and never moved to CPU.
- **Its own profile id**: the CPU text id plus **-npu-ptl** (and **…-vis140**
  for an image index), shared by the 270m, the 440m and the 740m, whose text
  towers are byte-identical.

## EmbeddingGemma 1 (`.tflite` + tokenizer)

Initialize the backend and the tokenizers:

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  // EmbeddingGemma 1 is gated; never hard-code the token.
  huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN').isEmpty
      ? null
      : const String.fromEnvironment('HUGGINGFACE_TOKEN'),
);
```

Pin both files to an immutable revision. The stable profile used by the vector
store must describe the exact weights, tokenizer, pooling, normalization, and
document/query prefix contract.

EmbeddingGemma 1 is a gated repository: the Hugging Face account behind the
token must accept the Gemma license on the model page before the download
succeeds.

```dart
const revision = '29888fcee3216acadc7e844906e5fe0d79a61875';
const profileId =
    'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
    'retrieval-prefix-meanpool-l2-v1';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/$revision/embeddinggemma-300M_seq256_mixed-precision.tflite',
    )
    .tokenizerFromNetwork(
      'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/$revision/sentencepiece.model',
    )
    .install();
```

On native, current LiteRT and ONNX embedding paths run on CPU, except the
EmbeddingGemma 2 per-SoC bundles, which run on a Qualcomm NPU
([above](#embeddinggemma-2-on-a-qualcomm-npu)), a Google Tensor one
([above](#embeddinggemma-2-on-a-google-tensor-npu)) or, on Windows, an Intel one
([above](#embeddinggemma-2-on-an-intel-npu)). On Web the `.tflite` and ONNX
paths try WebGPU and can fall back to WASM; EmbeddingGemma 2 runs on WebGPU
only, with no fallback. **preferredBackend** reaches the embedder only as
**npu** for the per-SoC bundles; **npu** on a generic EmbeddingGemma 2 bundle
throws **EmbeddingLoadException**, and any other request is not applied. Inspect
**EmbeddingModel.activeBackend** when the selected backend matters.

## Embedding API

```dart
final embedder = await FlutterEdgeAi.getActiveEmbedder();

final query = await embedder.embed(
  EmbeddingInput.text('Where does Flutter run?'),
  taskType: TaskType.retrievalQuery,
);
final documents = await embedder.embedAll(
  [for (final chunk in chunks) EmbeddingInput.text(chunk)],
  taskType: TaskType.retrievalDocument,
);
print('${embedder.dimension} dimensions, up to ${embedder.maxInputTokens} tokens');
```

- **taskType** is required and prefixes the text: **retrievalQuery** and
  **retrievalDocument** for search, **none** for no prefix, and
  **questionAnswering**, **factChecking**, **codeRetrieval**,
  **classification**, **clustering**, **sentenceSimilarity**. Native and Web
  apply the same prefix for the same task.
- **embedAll** keeps the input order, fails on the first error and takes a
  **cancelToken**.
- An input longer than **maxInputTokens** — task prefix, BOS and EOS
  included — is never truncated: it fails with
  **EmbeddingInputTooLongException**. A null **maxInputTokens** means the
  loaded pass cannot establish an effective limit; it does not mean unlimited.
- Every error of **embed** and **embedAll** arrives as a failed future and is
  an **EmbeddingException**: a closed model gives **EmbedderClosedException**.
  **getActiveEmbedder()** fails with **EmbeddingLoadException** for a model
  that cannot load, and with **StateError** when no embedder is installed or
  no registered backend can run it. An **EmbeddingInput** with no part or
  empty bytes throws **ArgumentError** when it is built.
- **generateEmbedding**, **generateEmbeddings** and **getDimension** were
  removed in 2.5.0; see [Migration](/docs/migration).

## RAG with the active core embedder

Install the embedder first: **open()** resolves the embedder's profile, which
loads the model.

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
      FilterField(name: 'year', type: FilterFieldType.number),
      FilterField(name: 'archived', type: FilterFieldType.bool),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
);

await index.add(
  id: 'doc-1',
  document: EmbeddingInput.text('Flutter runs on six platforms.'),
  metadata: '{"category":"flutter","year":2026,"archived":false}',
);

final hits = await index.search(
  query: EmbeddingInput.text('Where does Flutter run?'),
  topK: 5,
  threshold: 0.3,
  filter: Filter(
    must: [FieldEquals(key: 'category', value: 'flutter')],
    mustNot: [FieldEquals(key: 'archived', value: true)],
  ),
);

await index.flush();
```

**location** is an absolute path on native — a database file for SQLite, a
directory for Qdrant; build it from **getApplicationDocumentsDirectory()** — and
a plain name on Web. path_provider has no Web implementation, so call it only
off-web (see the sample under Independent text RAG).

**add** embeds with the document role and stores the text as the hit's
content; **search** uses the query role. Chunk text below the embedder's
**maxInputTokens**: a longer chunk throws **EmbeddingInputTooLongException**.
Every error of a Future-returning **RagIndex** method arrives as a failed
future.

**FlutterEdgeAiActiveEmbedder** borrows the model returned by
**FlutterEdgeAi.getActiveEmbedder()** and never closes it. It pins the model
that is active when it is created; after switching embedders it throws
**StateError** — open a new index at a new location. A request that failed
because core replaced the model before it ran is retried once.

- **FlutterEdgeAiActiveEmbedder.forActiveModel(namespace:)** derives the
  profile id from the installed file names, so installing a model under other
  file names changes the id and the old location refuses to open. Install with
  revision-qualified **filename:**s so new weights get a new id too.
- **FlutterEdgeAiActiveEmbedder(profileId: profileId)** takes an explicit id
  that versions the weights, tokenizer, pooling, normalization and prefixes.
  Profile ids may not contain control characters.

Queries over text documents use **TaskType.retrievalQuery**; pass
**queryTask:** for another task.

## Batch or vector-only RAG

For precomputed vectors, open a vector-only index with the profile of the
pipeline that produced them:

```dart
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(id: profileId, dimension: 768),
);

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vectors = await embedder.embedAll(
  [for (final document in documents) EmbeddingInput.text(document)],
  taskType: TaskType.retrievalDocument,
);
for (var i = 0; i < documents.length; i++) {
  await index.addVector(
    id: 'doc-$i',
    content: documents[i],
    embedding: vectors[i],
  );
}

final queryVector = await embedder.embed(
  EmbeddingInput.text('search text'),
  taskType: TaskType.retrievalQuery,
);
final hits = await index.searchVector(embedding: queryVector);
```

**addVector** and **searchVector** also work on an index opened with an
embedder, so batch ingest and text search can share one location. A purely
vector-based app never initializes Flutter Edge AI.

## Independent text RAG

Implement **RagEmbedder** when retrieval has its own embedding lifecycle:

```dart
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);

  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> resolveProfile() async =>
      EmbeddingProfile(id: 'my-model-and-pipeline-v1', dimension: 384);

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) =>
      model.embed('document: ${document.text}');

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) => model.embed('query: ${query.text}');
}

// kIsWeb: package:flutter/foundation.dart; p: package:path/path.dart.
// path_provider has no Web implementation, so call it only off-web.
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: kIsWeb
        ? 'custom-profile-v1.db'
        : p.join(
            (await getApplicationDocumentsDirectory()).path,
            'custom-profile-v1.db',
          ),
  ),
  embedder: AppEmbedder(myEmbeddingModel),
);
```

The index borrows a custom embedder too. Dispose the index before disposing the
embedder.

## Image and audio documents

A location holds documents of one modality, declared in
**VectorStoreSpec.documents** (text by default) and stored with the profile.
An image or audio index needs an embedder whose **modalities** include it; its
documents carry a **content** reference (a URI, file path or asset id), never
the media bytes. A text query over an image index is text-to-image search.
With the active embedder (**FlutterEdgeAiActiveEmbedder(supportImage: true)**
or **supportAudio: true**), an image index needs the EmbeddingGemma 2 440m or
740m bundle ([above](#embeddinggemma-2-images)) and an audio index the 740m
([above](#embeddinggemma-2-audio-and-combined-inputs)); on the Web from
litertlm 1.13.1 for images, 1.13.2 for audio. With any other model the index
fails to open with **EmbeddingLoadException**.
A custom **RagEmbedder** can embed media with any model. Cross-modal scores are not on one scale:
mixed corpora use one index per modality.

## Profiles, locations, and migration

One persistent location belongs to exactly one **EmbeddingProfile** and one
document modality. Use a new, profile-versioned location after changing
weights, tokenizer, pooling, normalization, prefixes, or dimensions.
**clear()** deletes documents but keeps the binding.

Stores written by flutter_edge_ai_rag 1.0 (sqlite and qdrant 2.0.x) open
unchanged as text locations. The API changes from rag 1.0 are listed in
[Migration](/docs/migration).

A nonempty database created before 2.0 has no stored profile. Prefer a new
location and re-index. If you can independently verify the exact original
embedding pipeline, explicit adoption is available:

```dart
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: legacyPath,
    allowLegacyProfileAdoption: true,
  ),
  profile: EmbeddingProfile(id: verifiedProfileId, dimension: 768),
);
```

The dimension is checked before the profile is persisted. The flag is an
attestation, not automatic detection, and applies to text locations only.

SQLite filter fields are physical **vec0** columns. Changing a schema requires a
new schema-versioned location and re-indexing; opening a database without a
schema and later reopening it with one cannot add columns.

## Filters

**Filter** combines **must** (AND), **should** (OR), and **mustNot** (NOT):

- **FieldEquals** for scalar equality.
- **FieldRange** for inclusive numeric bounds.
- **FieldMatchAny** for set membership.

Only fields declared in **VectorStoreSpec.filterSchema** are filterable. A
condition on an undeclared field throws **ArgumentError**. SQLite names must
match ^[A-Za-z][A-Za-z0-9_]*$ and cannot reuse **id**, **embedding**,
**content**, **metadata**, **distance**, or **k**; this narrower set is portable
to Qdrant.

## Ownership and durability

**RagIndex** owns its vector store and must be disposed. It borrows its embedder.
The shutdown order is therefore:

```dart
await index.flush();
await index.dispose();
await embedder.close(); // the EmbeddingModel from getActiveEmbedder(), or your custom embedder
```

Keep one app-owned index per persistent location. Make opening single-flight and
share its future across widgets. This is mandatory on Web, where the SQLite
provider holds an exclusive Web Lock for the location until **dispose()**.

**flush()** is required for qdrant-edge, drains IndexedDB for Web SQLite, and is
a no-op for native SQLite. **clear()** is an exclusive operation and preserves
the binding.

## Choosing a store

| | qdrant-edge | SQLite + sqlite-vec |
|---|---|---|
| Platforms | Android, iOS, macOS, Linux, Windows | Android, iOS, Web, macOS, Linux, Windows |
| Search | HNSW approximate | Exact KNN inside SQLite |
| Best fit | Native throughput at larger scale | Web, portability, deterministic exact results |
| Provider ID | qdrant | sqlite |

The providers implement the same RAG contract, so switching storage changes the
registered provider and **VectorStoreSpec.providerId**, not the retrieval
pipeline. Current measurements show qdrant-edge roughly 5–11× faster at
1k–10k documents; see the
[benchmark report](https://github.com/DenisovAV/flutter_edge_ai/blob/main/docs/benchmarks/rag_sqlite_vec_vs_qdrant.md).

**Writing this with a coding assistant?** **dart run skills@ get --all** installs
the **flutter-edge-ai-rag** skill with these profile, ownership, and filter rules.
