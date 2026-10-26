---
name: flutter-edge-ai-rag
description: Use when adding or debugging on-device RAG, semantic search, embeddings (EmbeddingGemma 2 .litertlm or .gguf through flutter_edge_ai_llama, EmbeddingGemma 1 or Gecko .tflite, ONNX models such as MiniLM), metadata filters, embedding profiles, image or audio document indexes, or pluggable sqlite-vec/qdrant-edge storage in a flutter_edge_ai app with flutter_edge_ai_rag, flutter_edge_ai_sqlite or flutter_edge_ai_qdrant. Also use when moving RAG code to flutter_edge_ai 2.0 or to flutter_edge_ai_rag 1.1 — FlutterEdgeAi.rag is undefined, initialize(vectorStore:) was removed, addText/searchText/activeEmbedderProfileId are undefined, or open() throws "No vector-store provider can handle providerId" or "is bound to" — and when QdrantLegacyStoreException or an embedding-profile mismatch is thrown.
---

# On-device RAG with Flutter Edge AI

## Non-negotiable architecture

1. RAG is not initialized by `FlutterEdgeAi.initialize()`. Use the independent
   `flutter_edge_ai_rag` package and an app-owned `FlutterEdgeAiRag` instance.
2. Storage packages are providers: `flutter_edge_ai_sqlite` registers
   `SqliteVectorStoreProvider`; `flutter_edge_ai_qdrant` registers
   `QdrantVectorStoreProvider`. Application code uses `RagIndex`.
3. One persistent location belongs to one stable `EmbeddingProfile` and one
   document modality (`VectorStoreSpec.documents`: text, image or audio). The
   profile id versions weights, tokenizer, pooling, normalization, and
   document/query prefixes; a mutable URL or file path is not an identity.
   Profile ids may not contain control characters.
4. Keep one live `RagIndex` per location, make opening single-flight, and share
   it across widgets. Web SQLite enforces this with an exclusive Web Lock.
5. Dispose indexes before `FlutterEdgeAi.dispose()` or before disposing a
   custom embedder. An index owns its vector store but only borrows its embedder.
6. Declare every filter field in `VectorStoreSpec.filterSchema` before the
   SQLite index is created. Changing SQLite's physical `vec0` schema requires a
   new schema-versioned location and re-index.
7. `location` is an absolute path on native — a database file for SQLite, a
   directory for Qdrant; build it from `getApplicationDocumentsDirectory()` —
   and a plain name on Web.

## Packages

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_rag flutter_edge_ai_sqlite path path_provider
```

For the default core embedder also add its runtime/tokenizer packages, usually
`flutter_edge_ai_litertlm` and `flutter_edge_ai_embeddings`. Replace SQLite
with `flutter_edge_ai_qdrant` for qdrant-edge on native platforms. SQLite runs
on Android, iOS, Web, macOS, Windows, and Linux; qdrant-edge has no Web arm.

`flutter_edge_ai_sqlite` needs Flutter 3.47 or newer. On older Flutter use
`flutter_edge_ai_qdrant` (native only) or upgrade Flutter.

`flutter_edge_ai_rag` re-exports `EmbeddingInput`, `EmbeddingModality`,
`TaskType` and the `EmbeddingException` family, so RAG code needs no core
import for them.

## Default active embedder

Initialize only embedding runtime pieces in core and install the embedder
before opening an index: `open()` resolves the embedder's profile, which loads
the model. Pin model downloads to an immutable revision.

`FlutterEdgeAiActiveEmbedder.forActiveModel(namespace:)` derives the profile id
from the installed file names (`'<namespace>@<files joined by +>'`, with `%`,
`@` and `+` inside a name percent-encoded), so
installing a model under different file names changes the id and the old
location refuses to open instead of mixing two embedding spaces. EmbeddingGemma
1 and 2 are both 768-dimensional: the id is the only thing that tells them
apart. The id follows file NAMES, not bytes: install the registry build, as
below — its file names carry the revision — so new weights under the same
download name get a new id too. An app that installed under other names keeps
them: its id follows those.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// EmbeddingGemma is gated: build with --dart-define=HUGGINGFACE_TOKEN=hf_...
const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  huggingFaceToken: hfToken.isEmpty ? null : hfToken,
);
// The registry build: commit 29888fce, revision-qualified file names.
await FlutterEdgeAi.installFromCatalog(LiteRtEmbedders.embeddinggemma300m.seq256)
    .install();

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
// Native: an absolute path to the database file. Web: a plain name.
const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'lang', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
);
```

The EmbeddingGemma repo is gated: the Hugging Face account behind the token
must accept the Gemma license on the model page, or the download is refused.
Keep the token out of source — it is compiled into the app, so a shipped app
should download from a repo that needs none.

An explicit id is the alternative when one store must outlive a file rename,
or serve several bundles known to produce identical vectors. Name everything
that shapes the vectors:

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

final embedder = FlutterEdgeAiActiveEmbedder(
  profileId:
      'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
      'retrieval-prefix-meanpool-l2-v1',
);
```

The adapter pins the embedding model that is active when it is created and
resolves the model again on every operation, so it follows core's embedder
cache. After switching embedders it throws `StateError`: create a new embedder
and open a new index at a new location. A request that failed because core
replaced the model before it ran (`EmbedderClosedException`) is retried once.
Queries over text documents use `TaskType.retrievalQuery`; pass `queryTask:`
for another task, e.g. `TaskType.questionAnswering`.

## GGUF embeddings (`flutter_edge_ai_llama` 0.0.3)

`LlamaEmbeddingBackend` in `flutter_edge_ai_llama` 0.0.3 (core 2.5.0, llamadart
0.15.1) runs EmbeddingGemma 2 GGUF text embeddings natively: measured on macOS
CPU/Metal and Linux/Windows CPU; Android (CPU only) and iOS are not qualified,
and only the Q8_0 file below is numerically qualified. A `.gguf` carries its own
tokenizer: a `tokenizerFrom…()` makes `install()` throw `ArgumentError`.

App setup (that package's README, *Add it to your app*, and `doc/platforms.md`):
`hooks: user_defines: llamadart: llamadart_native_runtimes: [llama_cpp]` in the
app's pubspec, or the workspace root's; on iOS/macOS also
`llamadart_llama_cpp_flutter: 0.15.0` in the app's own dependencies,
`flutter config --enable-swift-package-manager`, and iOS 16.4 / macOS 14
deployment targets; on Android arm64-v8a and x86_64 only. LiteRT-LM's macOS
CocoaPods recipe turns Swift Package Manager off, so GGUF and LiteRT-LM in one
macOS app are not qualified.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LlamaEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/'
      'bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf',
    ) // no tokenizer
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder();
```

- Text only: `supportImage`, `supportAudio` and `PreferredBackend.npu` throw
  `EmbeddingLoadException`. On Android (every device) and iOS simulators an
  explicit `gpu` falls back to CPU with a warning, or throws with
  `LlamaEmbeddingBackend(backendFallback: false)`; `activeBackend` reports what
  loaded.
- Only a mean-pooled `gemma-embedding2` GGUF loads; any other architecture or
  pooling throws `EmbeddingLoadException`.
- `maxInputTokens` is 1024, task prefix and special tokens included. A longer
  input throws `EmbeddingInputTooLongException` and is never truncated.
- A URL that does not end in `.gguf` needs
  `modelFromNetwork(url, filename: '<name>.gguf')`; without it `install()`
  throws `StateError` asking for a tokenizer.
- On Web it claims no file: with it the only backend registered, installing a
  `.gguf` throws `UnsupportedError` before anything is downloaded.
- Keep GGUF and LiteRT under separate profile ids, even at 768 dimensions.
  `FlutterEdgeAiActiveEmbedder.forActiveModel(namespace:)` does it by itself,
  because the file names differ; with an explicit `profileId`, name the format
  and quantization (e.g. `embeddinggemma2-gguf-q8_0`). A store bound to the
  LiteRT id refuses to open with the GGUF embedder.

## Custom embedding providers (core 2.5.0)

Engine authors import the SPI:

```dart
import 'package:flutter_edge_ai/engine.dart';
```

Core accepts self-contained `.gguf` embedding files without a separate
tokenizer (the app recipe is the GGUF embeddings section above). When backends are registered, installation requires one that can run
the file; with none registered, installation can proceed.
`flutter_edge_ai_embeddings` contains tokenizer implementations only; runtime
passes belong to their engine packages.

Providers declare explicit accelerator capabilities with `honouredBackends(spec)`;
core computes the cache key. Automatic requests reuse only a non-NPU embedder
for the same installed model, while NPU requests always retain a separate key.
Repeated explicit CPU/GPU requests reuse their originating fallback until a
rebuild is needed or the model is closed.
GPU-capable providers must report their actual loaded accelerator through
`EmbeddingPassInfo.activeBackend`; legacy fixed descriptors remain compatible.
Reporting providers print one release-visible WARNING per new fallback load,
including an NPU request; reuse does not repeat it.
`EmbeddingModel.maxInputTokens` is the effective loaded context/single-pass batch
capacity, including task prefixes and special tokens. A GGUF profile configured
with a 1024-token micro-batch cannot embed a longer chunk even if the file names
a larger context. Core hosts, caches and closes the pass.

## EmbeddingGemma 2 (one `.litertlm` file)

EmbeddingGemma 2 ships as one `.litertlm` bundle that carries its own
tokenizer: install the model alone — no `tokenizerFrom…()` call, and no
`flutter_edge_ai_embeddings` or `embeddingTokenizers:` needed. The repo is not
gated:

```dart
const eg2Revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';
// One id for the 270m, 440m and 740m bundles: their text towers are identical.
const eg2ProfileId = 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$eg2Revision/'
      'embeddinggemma-2-text-270m.litertlm',
    )
    .install();
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final limit = embedder.maxInputTokens; // 1024

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final eg2Index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: p.join(
      (await getApplicationDocumentsDirectory()).path,
      'knowledge-embeddinggemma2-text-v1.db',
    ),
  ),
  embedder: FlutterEdgeAiActiveEmbedder(profileId: eg2ProfileId),
);
```

- Android, iOS, macOS, Linux, Windows (`flutter_edge_ai_litertlm` 1.13.0 for
  text, 1.13.1 for images and audio), and Web on WebGPU through
  `@litert-lm/core`'s EmbeddingEngine (1.13.1 for text and images, 1.13.2 for
  audio and combined inputs). The Web page needs
  `window.EmbeddingEngine = m.EmbeddingEngine;` next to `window.Engine =
  m.Engine;` in its `@litert-lm/core` module script; without it the load fails
  with an `EmbeddingLoadException` naming that line. The browser needs WebGPU:
  the CPU (WebAssembly) path of `@litert-lm/core` 0.18.0 cannot read these
  bundles' external weights, so there is no CPU fallback, and a browser
  without WebGPU (no `navigator.gpu`, or no adapter) fails the load with an
  `EmbeddingLoadException` that says so.
- The 270m is text only: `getActiveEmbedder(supportImage: true)` throws
  `EmbeddingLoadException` naming the 440m bundle — natively before any engine
  or cache is made (below); on Web only after the bundle was read, when the
  runtime refuses to create the engine. `supportAudio: true` needs the 740m
  bundle (below): on the 270m and the 440m it throws `EmbeddingLoadException`
  naming the 740m, read from the bundle's container header before any engine
  exists — on Web too.
- `maxInputTokens` is 1024 — task prefix, BOS and EOS included. Keep chunks at
  512 tokens or fewer: memory grows with the input length. A longer text throws
  `EmbeddingInputTooLongException` with the exact `actualTokens` (natively
  from `flutter_edge_ai_litertlm` 1.13.1, from a truncated run; on Web read
  after the engine ran the whole input in 1024-token windows). Either way an
  over-long chunk still costs a full embedding before it is refused: split
  before embedding.
- It runs on CPU natively (`activeBackend` is `PreferredBackend.cpu`) and on
  WebGPU on Web (`PreferredBackend.gpu`), and refuses `PreferredBackend.npu`:
  the NPU runs the per-SoC bundles (next section). Web vectors therefore
  differ slightly from native ones — measured min cos about 0.995 for text and
  0.998 for images against the native CPU vectors — and retrieval across
  platforms holds: web queries find natively embedded images and native
  queries find web-embedded images, top-1 10/10 on the example's ten scenes.
  Natively it keeps a weight cache of about 71 MB, on top of the 165 MB
  bundle, in the app's cache directory: never backed up, and rebuilt at the
  next load if the OS clears it. A load whose cache file cannot be created (a
  path past Windows MAX_PATH, a directory the app cannot write to, possibly no
  free space at all) still runs, slower and larger, with a printed warning;
  `LiteRtEmbeddingBackend(requireWeightCache: true)`
  (`flutter_edge_ai_litertlm` 1.14.0) refuses it with `EmbeddingLoadException`
  instead — on CPU, and on the NPU with declared audio. A disk that fills
  while the cache is being written aborts the process in native code
  (XNNPack); no flag catches that. Web keeps no weight cache and ignores the
  flag, and so does a `.tflite` embedder (EmbeddingGemma 1, Gecko); each says
  so once, in a debug-build log line.
- EmbeddingGemma 1, 2 and Gecko all produce 768-d vectors but are different
  spaces: give each its own location and profile ID — the dimension check alone
  cannot tell them apart. `FlutterEdgeAiActiveEmbedder.forActiveModel` already
  gives them different ids (different file names); the explicit id above is for
  one text store shared by the three EmbeddingGemma 2 bundles.

### EmbeddingGemma 2 at 128, 256 or 512 dimensions (Matryoshka)

EmbeddingGemma 2 is trained with Matryoshka representation learning: the first
128, 256 or 512 values of its 768-d text vector, L2-normalized again, are an
embedding of their own. There is no API for it, and none is needed: take the
first N values of the vector the embedder returns and normalize them.
Measured 2026-10-22 on the 270m bundle (CPU, the ten golden texts): this is
the same vector LiteRT-LM's own `output_size` option returns (cos 1.000000 at
128, 256 and 512), each query still ranks its document first (5/5), and the
minimum cosine to Sentence Transformers fp32 cut to the same size is 0.976
(512) to 0.986 (128), against 0.977 at the full 768.
Images and audio were not measured; keep truncation to text.

```dart
import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

List<double> truncateEmbedding(List<double> vector, int dimension) {
  final head = vector.sublist(0, dimension);
  final norm = math.sqrt(head.fold(0.0, (sum, x) => sum + x * x));
  return [for (final x in head) x / norm];
}

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final full = await embedder.embed(
  EmbeddingInput.text('Flutter runs on six platforms.'),
  taskType: TaskType.retrievalDocument,
);
final small = truncateEmbedding(full, 256); // 256 values, unit length
```

A truncated vector is another embedding space. In RAG, wrap the embedder so
the index gets the smaller dimension and its own profile id: an id without
the size would let 256-d and 768-d vectors share a location.
`FlutterEdgeAiActiveEmbedder.forActiveModel` builds ids from file names only,
so it cannot tell the sizes apart either.

```text
final class MatryoshkaEmbedder implements RagEmbedder {
  MatryoshkaEmbedder(this.inner, {required this.dimension, required this.profileId});

  final RagEmbedder inner;
  final int dimension;
  final String profileId; // a new space: never the full-size id

  @override
  Future<EmbeddingProfile> resolveProfile() async {
    final full = await inner.resolveProfile();
    if (dimension > full.dimension) {
      throw ArgumentError.value(dimension, 'dimension', 'exceeds ${full.dimension}');
    }
    return EmbeddingProfile(id: profileId, dimension: dimension);
  }

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) async =>
      truncateEmbedding(await inner.embedDocument(document), dimension);

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) async => truncateEmbedding(
    await inner.embedQuery(query, documentModality: documentModality),
    dimension,
  );
}

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  embedder: MatryoshkaEmbedder(
    FlutterEdgeAiActiveEmbedder(profileId: eg2ProfileId),
    dimension: 256,
    profileId: '$eg2ProfileId-mrl256',
  ),
);
```

Only Matryoshka-trained models keep their quality this way. EmbeddingGemma 1,
Gecko, MiniLM and the GGUF EmbeddingGemma 2 were not measured here; do not
truncate a model without measuring it.

### EmbeddingGemma 2 on a Qualcomm NPU (`flutter_edge_ai_litertlm` 1.13.1)

The same repos hold each bundle compiled for one SoC's NPU
(`embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm`,
`embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm`, …). It runs on
Qualcomm Android (arm64) and Qualcomm Linux arm64, in an app whose pubspec (the
workspace root's, for a workspace member) sets
`hooks: user_defines: flutter_edge_ai_litertlm: qualcomm_npu: true` (the flag
the LLM NPU path uses), loaded with `preferredBackend: PreferredBackend.npu`:

```dart
const eg2Revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';
// Its own id: NPU vectors are not the CPU bundle's. Shared by the SoC's 270m
// and 440m (byte-identical text towers).
const npuProfileId =
    'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$eg2Revision/'
      'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm',
    )
    .install();
final npu = await FlutterEdgeAi.getActiveEmbedder(
  preferredBackend: PreferredBackend.npu,
);
assert(npu.activeBackend == PreferredBackend.npu);

final rag = FlutterEdgeAiRag(providers: const [SqliteVectorStoreProvider()]);
final npuIndex = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: p.join(
      (await getApplicationDocumentsDirectory()).path,
      'knowledge-embeddinggemma2-npu-sm8850.db',
    ),
  ),
  // The adapter loads the embedder per operation: pass npu here too.
  embedder: FlutterEdgeAiActiveEmbedder(
    profileId: npuProfileId,
    preferredBackend: PreferredBackend.npu,
  ),
);
```

- Run on device: SM8850, SM8650 and QCS8275. Google also publishes SM8550,
  SM8750 (accepted by the loader, not run by us), Intel PTL (Windows, below),
  Tensor G5/G6 (below; G6 run, G5 not) and MediaTek MT6991/MT6993 (below).
  Per build: https://flutteredge.ai/docs/registry. What a bundle targets is
  read from the bundle.
- Its vectors are close to the CPU bundle's, not equal (SM8650: cosine
  0.79–0.86 for a few words, 0.99 from about 200 words; images 0.86–0.88), so
  never compare NPU vectors with CPU ones; within the NPU space retrieval
  holds (text → image 10/10).
- Nothing falls back: a per-SoC bundle without `npu`, the generic bundle with
  `npu`, `npu` on iOS/macOS/Linux x64/Web, a Qualcomm bundle on Windows, a
  Tensor or MediaTek bundle off Android, a build without the bundle vendor's flag
  (`qualcomm_npu`, `google_tensor_npu`, `mediatek_npu`), a device without a
  reachable NPU of
  that vendor (for Tensor: not a Tensor Pixel on Android 16 or later, or a BP2A
  build; for MediaTek: below Android 12, a SoC manufacturer other than
  Mediatek or MTK, or no NeuroPilot adapter opens in the app), and a bundle the NPU cannot run (another SoC's or Tensor
  generation's) each throw
  `EmbeddingLoadException` with the fix. A loaded embedder is never reused for
  the other backend.
- Give an NPU index its own profile id (above); never open a CPU index with an
  NPU embedder or the reverse. `FlutterEdgeAiActiveEmbedder.forActiveModel`
  keys on the file name, so it separates them by itself.
- **Intel Panther Lake (Windows x64, `flutter_edge_ai_litertlm` 1.13.2).** `…_Intel_PTL.litertlm` (270m, 440m, 740m) loads the
  same way with `preferredBackend: PreferredBackend.npu`, with no opt-in flag:
  every Windows x64 build carries the Intel stack (LiteRtDispatch.dll,
  OpenVINO, TBB) beside the executable, and its absence is refused by name.
  Profile id: the CPU text id plus `-npu-ptl`, shared by the 270m, the 440m and
  the 740m.
  An Intel bundle on Android or Linux is refused. The 270m was measured on a
  Panther Lake PC (2026-10-21, OpenVINO 2026.4.1, the stack of
  `flutter_edge_ai_litertlm` 1.17.0): 768-dimensional vectors, load about
  0.9 s; the 440m is not measured. Each 270m load writes a 74.5 MB weight bank
  to `%TEMP%` (the 440m's is not measured), deleted when the embedder closes.
- **Google Tensor G5/G6 (Android arm64, `flutter_edge_ai_litertlm` 1.15.0).**
  `…_Google_Tensor_G5.litertlm` / `…_Google_Tensor_G6.litertlm` (270m, 440m)
  load the same way with `preferredBackend: PreferredBackend.npu`, in an app
  whose pubspec (the workspace root's, for a workspace member) sets
  `hooks: user_defines: flutter_edge_ai_litertlm: google_tensor_npu: true` (the
  flag the LLM path uses), on
  a Pixel with that Tensor generation and Android 16 or later, not a BP2A
  build. Profile id: the CPU text id plus the SoC, e.g. `-npu-tensor_g6`,
  shared by the 270m and the 440m. Run on a Pixel 11 (Tensor G6) with a debug
  build; a Tensor G5 and a release-signed build are not run yet.
- **MediaTek MT6991/MT6993 (Android arm64, `flutter_edge_ai_litertlm` 1.17.0).**
  `…_MediaTek_MT6991.litertlm` / `…_MediaTek_MT6993.litertlm` are accepted the
  same way with `preferredBackend: PreferredBackend.npu`, in an app whose pubspec
  (the workspace root's, for a workspace member) sets
  `hooks: user_defines: flutter_edge_ai_litertlm: mediatek_npu: true`, on a phone with that SoC, Android 12 or later, whose
  vendor exposes NeuroPilot to apps. Profile id: the CPU text id plus the SoC,
  e.g. `-npu-mt6991`. Not run on an MT6991/MT6993 phone yet; the LLM path
  runs on an MT6989.

### EmbeddingGemma 2 images (440m; `flutter_edge_ai_litertlm` 1.13.1 native, 1.13.1 Web)

The 440m bundle adds a vision encoder to the same text tower, so one model
embeds both and a text finds photos. Install it like the 270m (ungated):

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const visionRevision = 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8';
// The text id of the 270m section; image vectors also depend on the vision
// budget, so image indexes add it.
const photosProfileId =
    'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-vis140';

await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-vision-440m-litert-lm/resolve/$visionRevision/'
      'embeddinggemma-2-text-vision-440m.litertlm',
      filename: 'embeddinggemma-2-text-vision-440m__rev-e301f74d5551.litertlm',
    )
    .install();

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final photos = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: p.join(
      (await getApplicationDocumentsDirectory()).path,
      'photos-embeddinggemma2-vis140.db',
    ),
    documents: EmbeddingModality.image,
  ),
  embedder: FlutterEdgeAiActiveEmbedder(
    profileId: photosProfileId,
    supportImage: true,
  ),
);
await photos.add(
  id: 'photo-1',
  document: EmbeddingInput.image(bytes), // upright, ≤ 1024 px: see below
  content: path, // a reference to the photo, never its bytes
);
final hits = await photos.search(query: EmbeddingInput.text('a red bicycle'));
```

Pass upright, downscaled images. The engine decodes the file itself, ignores
EXIF orientation — a portrait phone photo, stored sideways with an orientation
tag, is embedded lying on its side (measured cos 0.89 against the upright
picture) — and decodes at full size, which a 12 MP photo pays for. Decode with
Flutter first: it applies the orientation and decodes straight to the target
size:

```dart
import 'dart:math' as math;
import 'dart:ui' as ui;

final codec = await ui.instantiateImageCodecWithSize(
  await ui.ImmutableBuffer.fromUint8List(bytes), // the photo as picked
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
final upright = EmbeddingInput.image(png!.buffer.asUint8List());
```

This also converts what Flutter decodes and the engine does not (WebP; HEIC on
Android). Keep the original for display; give the model the result. The same
code runs on Web (CanvasKit and skwasm decode through the browser), on the
page itself: there are no isolates there.

- Formats the engine decodes: JPEG, PNG, GIF and BMP. HEIC, WebP, TIFF and
  AVIF throw `EmbeddingFormatNotSupportedException` (with `detected` and
  `accepted`) before anything is sent — decode them as above. A corrupt or
  truncated file of an accepted type reaches the model and fails with
  `EmbeddingEngineException` (`nativeCode` 3 on native; on Web the message
  carries the runtime's reason); the model keeps working.
- Vision budget: 140 tokens per image by default (closest to the reference
  model, min cos 0.985 on our test images);
  `LiteRtEmbeddingBackend(visionTokensPerImage: 70)` — what the model card and
  Google AI Edge Gallery use — is about twice as fast with slightly lower
  fidelity (min cos 0.970); give its image indexes their own id (`…-vis70`). Any other value throws `EmbeddingLoadException`. Text vectors
  do not depend on it. `forActiveModel` ids follow file names only, so an app
  that changes the budget puts it in the namespace (`'photos-vis70'`).
- On Web the vision encoder does not fit next to a loaded `.litertlm` LLM:
  the page's `@litert-lm/core` module has 4 GB of WebAssembly memory, and the
  440m's vision engine (about 3.3 GB) and Gemma 4 E2B do not share it —
  whichever loads second fails, the embedder with an `EmbeddingLoadException`
  that says to close the LLM first. Text-only embedding loads next to the LLM.
- Cost (CPU, measured): 388 MB on disk plus a 218 MB vision weight cache
  written every time the model loads — also when it only embeds text. The
  first image adds RAM: about 385 MB on an M4 Pro Mac, about 500 MB on a
  Pixel 8. Per image at 140 tokens: about 0.35 s on an Apple-silicon Mac,
  about 2 s on an Android flagship (Pixel 8 Pro 1.8 s, Pixel 8a 2.3 s), more
  on mid-range phones and rising under sustained load as the phone heats up;
  70 tokens takes about half. A 440m loaded for text alone still loads its
  vision tower: apps that embed only text use the 270m. LiteRT-LM's thread
  setting reaches the text tower only. Close the embedder after a large photo
  ingest on low-RAM devices.
- A text query over an image index is sent raw (`TaskType.none`): measured,
  the retrieval-query prefix found the same photos with a smaller margin. Do
  not set `queryTask` for it: that applies to text documents only.

### EmbeddingGemma 2 audio and combined inputs (740m; `flutter_edge_ai_litertlm` 1.13.1 native, 1.13.2 Web)

The 740m bundle (`litert-community/embeddinggemma-2-740m-litert-lm`, revision
`24d962e906c7d332c6428e71c9676855024569e2`, ungated, 485 MB) has the 440m's
text and vision towers — the same text and image vectors, so the same profile
ids — plus an audio encoder. On Web audio and combined inputs run on WebGPU
(from 1.13.2) with the same formats, limits and errors.

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final clips = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: path, // its own location: one modality per location
    documents: EmbeddingModality.audio,
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(
    namespace: 'clips',
    supportAudio: true,
  ),
);
await clips.add(
  id: 'memo-1',
  document: EmbeddingInput.audio(bytes), // encoded WAV, MP3 or FLAC bytes
  content: 'file:///memos/1.wav',
);
final hits = await clips.search(
  query: EmbeddingInput.text('turn off the kitchen lights'),
);

// Several parts in one vector (flutter_edge_ai 2.3.1), outside an index:
final embedder = await FlutterEdgeAi.getActiveEmbedder(
  supportImage: true,
  supportAudio: true,
);
final vector = await embedder.embed(
  EmbeddingInput(text: 'kitchen', audio: bytes),
  taskType: TaskType.retrievalDocument,
);
```

- Formats: WAV, MP3 and FLAC, any rate and channel count (the engine mixes
  down to mono and resamples to 16 kHz). Ogg and M4A throw
  `EmbeddingFormatNotSupportedException` before anything is sent; a corrupt
  file of an accepted type throws `EmbeddingEngineException` (`nativeCode` 2
  on native; on Web the runtime's message) and the model keeps working. One
  clip per vector.
- Length: about 25 tokens per second, so up to about 40 seconds fit the
  1024-token cap; a 60-second clip throws `EmbeddingInputTooLongException`
  with `actualTokens` 1504. Split long recordings.
- `EmbeddingInput(text:, images:, audio:)` puts the text (with its task
  prefix), then the images in order, then the audio into one vector, whatever
  order the arguments are written in. Declare every medium it carries. Any
  input with more than one part — several modalities, or several images — is
  a combined input: an engine that embeds one part per vector (every other one
  here, and EmbeddingGemma 2 on Web before `flutter_edge_ai_litertlm` 1.13.2)
  refuses it with
  `UnsupportedEmbeddingCombinationException` before anything is sent.
- An audio index keeps the text profile id: audio vectors do not depend on the
  vision budget, and the store's `documents` modality keeps it apart from a
  text store. A text query over it is sent raw (`TaskType.none`).
- Audio vectors are not bit-portable: the audio encoder quantizes activations
  to 8 bits, so another CPU kernel can move a clip's vector by up to cos 0.05
  (text and image vectors do not move that way); Web (WebGPU) audio vectors
  are within cos 0.97 of the native ones. Retrieval holds: every test
  sentence was found by its text query on every build measured, Web included.
- Cost (CPU, M4 Pro Mac): 385 MB of weight caches written at every load (text
  71 MB, vision 218 MB, audio 95 MB), also for text-only use; about 0.2–0.3 s
  per 3-second clip. On Web (WebGPU, Tesla T4) about 0.3 s per clip after a
  first one of about 4 s, and no weight cache. Use the 270m for text, the 440m
  for text and images.

## Index and search

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'lang', type: FilterFieldType.string),
      FilterField(name: 'year', type: FilterFieldType.number),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
);
await index.add(
  id: 'doc-1',
  document: EmbeddingInput.text(chunk),
  metadata: jsonEncode({'lang': 'en', 'year': 2024}),
);

final hits = await index.search(
  query: EmbeddingInput.text(question),
  topK: 5,
  threshold: 0.3,
  filter: Filter(
    must: [FieldEquals(key: 'lang', value: 'en')],
    mustNot: [FieldRange(key: 'year', lte: 2010)],
  ),
);

await index.flush();
```

`add` embeds with the embedder's document role and stores the chunk as the
hit's `content` (pass `content:` to store something else); `search` uses the
query role. For precomputed batches, embed with `TaskType.retrievalDocument`,
then use `addVector`; use `searchVector` for precomputed queries. `remove`,
`stats`, `clear`, and `flush` operate on the owned index. Flush after a write
batch: it is required for qdrant durability, a Web SQLite durability fence,
and a no-op on native SQLite. Every field a `Filter` names must be declared in
`filterSchema`; an undeclared one throws `ArgumentError`.

Chunk text below the embedder's input limit,
`(await FlutterEdgeAi.getActiveEmbedder()).maxInputTokens` — 256 tokens for the
EmbeddingGemma seq256 file above, task prefix, BOS and EOS included. A longer
chunk or query is never truncated: `add` and `search` throw
`EmbeddingInputTooLongException`, whose `maxInputTokens` and `actualTokens`
say by how much. A null `maxInputTokens` means the loaded pass cannot establish
an effective limit, not that input is unlimited.

## Image and audio documents

A location holds documents of one modality. An image index needs an embedder
that embeds images (`RagEmbedder.modalities`); `open()` refuses one that does
not with `ArgumentError`. `content` is required and is a reference to the
media — a URI, file path or asset id — never its bytes; search results return
it. A text query over an image index is text-to-image search:

```dart
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';

final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final photos = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: path, // its own location: one modality per location
    documents: EmbeddingModality.image,
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(
    namespace: 'photos',
    supportImage: true,
  ),
);
await photos.add(
  id: 'photo-1',
  document: EmbeddingInput.image(bytes), // encoded JPEG/PNG bytes
  content: 'content://media/external/images/1',
);
final matches = await photos.search(query: EmbeddingInput.text('a red bicycle'));
```

The active embedder embeds images with the EmbeddingGemma 2 440m or 740m
bundle (above; on Web from `flutter_edge_ai_litertlm` 1.13.1). With any other
model — the 270m, EmbeddingGemma 1, Gecko, ONNX, a GGUF —
`getActiveEmbedder(supportImage: true)`, and therefore `open()` of an image
index with the active embedder, fails with `EmbeddingLoadException`. A
custom `RagEmbedder` can embed media with any model. A text index and an image
index can share one installed model: each adapter declares what it needs, and
core reloads the embedder once with both.

Cross-modal scores are not on one scale, so mixed corpora use one index per
modality and the app merges results. Text locations open in both directions
between this release and flutter_edge_ai_rag 1.0 with the 2.0.x stores. On an
image or audio location those older releases refuse every open that names a
profile, legacy adoption, every text operation and a rebind.

## Vector-only and custom embedders

RAG can run without `FlutterEdgeAi.initialize()`.

For vector-only use, open with the profile of the pipeline that produced the
vectors and call only vector APIs:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const databaseName = 'vectors-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(
    id: 'my-precomputed-embedding-pipeline-v1',
    dimension: 768,
  ),
);
final vector = List<double>.filled(768, 0);
final queryVector = List<double>.filled(768, 0);
await index.addVector(id: 'doc-1', content: chunk, embedding: vector);
final hits = await index.searchVector(embedding: queryVector);
```

For independent RAG, implement `RagEmbedder`. It maps the document and query
roles to its model's conventions. `EmbeddingProfile` has no `const`
constructor — it validates its arguments:

```text
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);
  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> resolveProfile() async => EmbeddingProfile(
    id: 'my-model-tokenizer-pooling-prefix-v1',
    dimension: 384,
  );

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

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: customDatabasePath, // absolute path on native, a name on Web
  ),
  embedder: AppEmbedder(model),
);
```

Different indexes may use different embedders. Never mix their vectors in one
location, even when dimensions match.

## qdrant-edge storage (native only)

```dart
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final rag = FlutterEdgeAiRag(
  providers: const [QdrantVectorStoreProvider()],
);
// A directory, not a file — qdrant creates its shard files inside it.
final storeDirectory = p.join(
  (await getApplicationDocumentsDirectory()).path,
  'knowledge-qdrant-v1',
);
try {
  final index = await rag.open(
    spec: VectorStoreSpec(providerId: 'qdrant', location: storeDirectory),
    embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
  );
} on QdrantLegacyStoreException catch (e) {
  // Written by flutter_gemma_rag_qdrant 1.2 or earlier: not readable.
  // e.message names the files to delete; delete them, then re-index.
  print(e.message);
}
```

`QdrantVectorStoreProvider` has no static providerId constant: pass the string
`'qdrant'`. Keep the directory apart from any SQLite database. A store written
by `flutter_gemma_rag_qdrant` 1.2 or earlier makes `open()` throw
`QdrantLegacyStoreException`: its format cannot be read or adopted, so delete
the files its message names and re-index. Catch that type, not the base
`VectorStoreException` — the base type also covers a shard that is only locked
by another open store. The legacy-adoption path below applies to profile-less
qdrant stores written by 1.3.x.

## Existing stores and lifecycle

A nonempty 1.x store has no profile metadata. Prefer a new profile-versioned
location and re-index. Only when the exact old embedding pipeline is known may
the app open it with that profile and `allowLegacyProfileAdoption: true`. That
flag is a `VectorStoreSpec` field, not an `open()` argument, applies to text
locations only, and the provider also checks vector dimension:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const oldDatabaseName = 'rag.db'; // the location the 1.x app already used
final databasePath = kIsWeb
    ? oldDatabaseName
    : p.join((await getApplicationDocumentsDirectory()).path, oldDatabaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
    allowLegacyProfileAdoption: true,
  ),
  profile: EmbeddingProfile(
    id: 'the-verified-old-embedding-pipeline-v1',
    dimension: 768,
  ),
);
```

Stores written by flutter_edge_ai_rag 1.0 (`flutter_edge_ai_sqlite` /
`flutter_edge_ai_qdrant` 2.0.x) open unchanged as text locations.

Make open/dispose app-owned and idempotent:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
Future<RagIndex>? opening;
Future<void>? disposing;

opening ??= rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(id: 'embedding-pipeline-v1', dimension: 768),
);
disposing ??= () async {
  final pending = opening;
  if (pending != null) await (await pending).dispose();
}();
await disposing;
```

Do not create an index in each widget or reopen the same Web location while a
previous index is live. Shutdown order is:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const databaseName = 'knowledge-v1.db';
final databasePath = kIsWeb
    ? databaseName
    : p.join((await getApplicationDocumentsDirectory()).path, databaseName);
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
final index = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: SqliteVectorStoreProvider.providerId,
    location: databasePath,
  ),
  profile: EmbeddingProfile(id: 'embedding-pipeline-v1', dimension: 768),
);
await index.dispose();
await FlutterEdgeAi.dispose(); // resets core's registries; closes no model
```

## Moving from flutter_edge_ai_rag 1.0 to 1.1

| rag 1.0 | rag 1.1 |
| --- | --- |
| `open(spec:, activeEmbedderProfileId: id)` | `open(spec:, embedder: FlutterEdgeAiActiveEmbedder(profileId: id))`, or `.forActiveModel(namespace:)` |
| `open(spec:, embeddingProfile: p)` (vectors only) | `openVectors(spec:, profile: p)` |
| `open()` bound the profile on the first text operation | `open()` resolves the profile and binds the location at once; install the embedder first |
| `index.addText(id:, content: c)` | `index.add(id:, document: EmbeddingInput.text(c))` |
| `index.searchText(query: q)` | `index.search(query: EmbeddingInput.text(q))` |
| `index.embeddingProfile` could be null | never null; `index.documents` names the modality |
| `RagEmbedder` with a `profile` getter, `embedDocument(String)`, `embedQuery(String)` | `resolveProfile()`, `modalities`, `embedDocument(EmbeddingInput)`, `embedQuery(EmbeddingInput, documentModality:)` |
| a filter on an undeclared field was ignored | `ArgumentError` |
| `VectorStoreRepository` (`implements`), `readEmbeddingProfile`/`bindEmbeddingProfile` | `abstract base class` (`extends`), `readBinding()`/`bind(VectorStoreBinding)` |

Upgrade every flutter_edge_ai package together: the stores of this release
need flutter_edge_ai_rag 1.1.

## Moving from 1.x core RAG to 2.0

In flutter_edge_ai 2.0 RAG left core: the `FlutterEdgeAi.rag.…` calls and the
`vectorStore:` and `filterSchema:` parameters of `FlutterEdgeAi.initialize()`
are gone. Add `flutter_edge_ai_rag` and a storage package, remove those two
parameters, and open a `RagIndex`:

| 1.x (`FlutterEdgeAi.rag.…`) | `RagIndex` |
| --- | --- |
| `initialize(vectorStore: ...)` on core | `FlutterEdgeAiRag(providers: [...])` |
| `rag.initialize(location)` | `rag.open(spec: VectorStoreSpec(...), embedder: ...)` |
| `addDocument(...)` | `add(id:, document: EmbeddingInput.text(...))` |
| `addDocumentWithEmbedding(...)` | `addVector(...)` |
| `searchSimilar(query: ...)` | `search(query: EmbeddingInput.text(...))` |
| `removeDocument(id: ...)` | `remove(id: ...)` |
| `stats()` / `flush()` / `clear()` | the same methods on the index |

`No vector-store provider can handle providerId "…"` means the provider for
that ID was not passed to `FlutterEdgeAiRag(providers: ...)`, or cannot run on
this platform (qdrant on Web). A nonempty store written by 1.x is usable only
through the legacy-adoption path above, or after re-indexing into a new
location.

## Web assets and common failures

- Copy `web/rag/sqlite3.wasm` from `flutter_edge_ai_sqlite` to the same path in
  the app. Copy the four matching LiteRT embedding files from
  `flutter_edge_ai_litertlm/web/` when that runtime is used, and copy them
  again after upgrading it: a stale `litert_embeddings.js` fails
  `getActiveEmbedder()` with an `EmbeddingLoadException` that names the file.
  EmbeddingGemma 2 (`.litertlm`) needs none of those files, only
  `window.EmbeddingEngine = m.EmbeddingEngine;` in the `@litert-lm/core`
  module script of `web/index.html`, and a browser with WebGPU.
- `EmbeddingLoadException` starting "EmbeddingGemma 2 on the web needs
  WebGPU": the browser has no `navigator.gpu` or no GPU adapter. There is no
  CPU path for these bundles on Web; use a browser with WebGPU enabled.
- `ArgumentError` naming an undeclared filter field: add it to `filterSchema`.
  SQLite names must match `^[A-Za-z][A-Za-z0-9_]*$` and avoid reserved columns.
- `StateError: Vector store "…" is bound to …, not …`: the location belongs to
  another profile or document modality — model or preprocessing bytes
  changed, a different model is installed, or the wrong location was opened.
  Do not bypass it; choose the correct profile/location.
- Vector-only indexes need `openVectors(profile:)`: raw numbers cannot
  identify their embedding space.
- `EmbeddingInputTooLongException` from `add` or `search`: the text is longer
  than the embedder's `maxInputTokens`. Split it into smaller chunks; older
  releases truncated it silently. With EmbeddingGemma 2 its `actualTokens` is
  the exact count (natively from `flutter_edge_ai_litertlm` 1.13.1).
- `EmbeddingLoadException` from `open()` of an image index: the installed
  model has no vision encoder — "has no vision encoder; install
  embeddinggemma-2-text-vision-440m" on the 270m — or is not an EmbeddingGemma
  2 bundle. From an audio index: "has no audio encoder; install
  embeddinggemma-2-740m" on the 270m and the 440m, natively and on Web.
- `EmbeddingFormatNotSupportedException` from `add` or `search` on an image
  index: HEIC, WebP, TIFF or AVIF; convert to JPEG or PNG.
- `VectorStoreException` "… is not a valid embedding profile" on open: the
  location was bound by flutter_edge_ai_rag 1.0 to an id with a control
  character, which 1.1 refuses; this version cannot open it.
- `StateError` mentioning that the active embedding model changed: an adapter
  is pinned to the model active when it was created. After switching
  embedders, create a new embedder and open a new index at a new location.
