---
name: flutter-edge-ai-rag
description: Use when adding or debugging on-device RAG, semantic search, text embeddings (EmbeddingGemma 1 .tflite, EmbeddingGemma 2 .litertlm), metadata filters, embedding profiles, image or audio document indexes, or pluggable sqlite-vec/qdrant-edge storage in a flutter_edge_ai app with flutter_edge_ai_rag, flutter_edge_ai_sqlite or flutter_edge_ai_qdrant. Also use when moving RAG code to flutter_edge_ai 2.0 or to flutter_edge_ai_rag 1.1 — FlutterEdgeAi.rag is undefined, initialize(vectorStore:) was removed, addText/searchText/activeEmbedderProfileId are undefined, or open() throws "No vector-store provider can handle providerId" or "is bound to" — and when QdrantLegacyStoreException or an embedding-profile mismatch is thrown.
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
apart. The id follows file NAMES, not bytes: install with revision-qualified
`filename:`s, as below, so new weights under the same download name get a new
id too.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const revision = '29888fcee3216acadc7e844906e5fe0d79a61875';
const modelBase =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/$revision';
// EmbeddingGemma is gated: build with --dart-define=HUGGINGFACE_TOKEN=hf_...
const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
  embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  huggingFaceToken: hfToken.isEmpty ? null : hfToken,
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      '$modelBase/embeddinggemma-300M_seq256_mixed-precision.tflite',
      filename: 'embeddinggemma-300m-seq256-mp__rev-29888fcee321.tflite',
    )
    .tokenizerFromNetwork(
      '$modelBase/sentencepiece.model',
      filename: 'embeddinggemma-300m__sentencepiece__rev-29888fcee321.model',
    )
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

## EmbeddingGemma 2 (one `.litertlm` file, native)

EmbeddingGemma 2 text ships as one `.litertlm` bundle that carries its own
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

- Native only with `flutter_edge_ai_litertlm` 1.13.0: Android, iOS, macOS,
  Linux, Windows. On Web `install()` refuses the `.litertlm` embedder with an
  `UnsupportedError` before downloading anything.
- Text only for now: `getActiveEmbedder(supportImage: true)` or
  `supportAudio: true` throws `EmbeddingLoadException` (images arrive in
  1.14.0, audio in 1.16.0).
- `maxInputTokens` is 1024 — task prefix, BOS and EOS included. Keep chunks at
  512 tokens or fewer: memory grows with the input length. A longer text throws
  `EmbeddingInputTooLongException` whose `actualTokens` is null — LiteRT-LM
  reports the overflow without a count.
- It runs on CPU (`activeBackend` is `PreferredBackend.cpu`) and keeps a weight
  cache of about 71 MB, on top of the 165 MB bundle, in the app's cache
  directory: never backed up, and rebuilt at the next load if the OS clears
  it.
- EmbeddingGemma 1 and 2 both produce 768-d vectors but are different spaces:
  give each its own location and profile ID — the dimension check alone cannot
  tell them apart. `FlutterEdgeAiActiveEmbedder.forActiveModel` already gives
  them different ids (different file names); the explicit id above is for one
  text store shared by the three EmbeddingGemma 2 bundles.

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
say by how much. A null `maxInputTokens` means the model file declares no
limit.

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

The embedders bundled with this release embed text only:
`getActiveEmbedder(supportImage: true)` — and therefore `open()` of an image
index with the active embedder — fails with `EmbeddingLoadException`. A custom
`RagEmbedder` can embed media today. A text index and an image index can share
one installed model: each adapter declares what it needs, and core reloads
the embedder once with both.

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
await FlutterEdgeAi.dispose();
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
  null.
- `EmbeddingLoadException` from `open()` of an image or audio index: the
  installed model, or every embedder bundled with this release, embeds text
  only.
- `VectorStoreException` "… is not a valid embedding profile" on open: the
  location was bound by flutter_edge_ai_rag 1.0 to an id with a control
  character, which 1.1 refuses; this version cannot open it.
- `StateError` mentioning that the active embedding model changed: an adapter
  is pinned to the model active when it was created. After switching
  embedders, create a new embedder and open a new index at a new location.
