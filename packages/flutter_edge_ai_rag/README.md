# flutter_edge_ai_rag

Pluggable, instance-scoped retrieval-augmented generation for
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai). The package owns
RAG orchestration and contracts; storage implementations are supplied by
separate packages such as `flutter_edge_ai_qdrant` and
`flutter_edge_ai_sqlite`.

Coming from `flutter_edge_ai` 1.x, where RAG lived in core, or from
`flutter_edge_ai_rag` 1.0? See the
[migration guide](https://flutteredge.ai/docs/migration).

Add this package and at least one storage provider:

```yaml
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_rag: ^1.1.0
  flutter_edge_ai_sqlite: ^2.1.0   # all six platforms; needs Flutter 3.47
  # or flutter_edge_ai_qdrant: ^2.1.0 (native only)
```

> **1.1.0 needs `flutter_edge_ai` 2.3.0 and the 2.1.0 stores.** Upgrade every
> flutter_edge_ai package together (`flutter pub upgrade`): with core 2.3.0
> the minimums are `flutter_edge_ai_litertlm` 1.13.0 ·
> `flutter_edge_ai_embeddings` 2.3.0 · `flutter_edge_ai_onnx` 0.5.8 ·
> `flutter_edge_ai_sqlite` 2.1.0 · `flutter_edge_ai_qdrant` 2.1.0 ·
> `flutter_edge_ai_mediapipe` 1.2.2 · `flutter_edge_ai_builtin_ai` 0.3.5 ·
> `flutter_edge_ai_speech` 0.5.6 · `flutter_edge_ai_agent` 0.2.9 ·
> `genkit_flutter_edge_ai` 0.9.1. A 2.0.x store does not compile against
> rag 1.1.

This package re-exports `EmbeddingInput`, `EmbeddingModality`, `TaskType` and
the `EmbeddingException` family from core, so RAG code needs no other import
for them.

## Index and search with the active embedder

Install the embedder first: `open()` resolves the embedder's profile, which
loads the model.

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final rag = FlutterEdgeAiRag(
  providers: [const SqliteVectorStoreProvider()],
);

// An absolute path on native, a plain name on Web. path_provider has no Web
// implementation, so it is only called on native.
Future<String> ragLocation(String name) async => kIsWeb
    ? name
    : p.join((await getApplicationDocumentsDirectory()).path, name);

final location = await ragLocation('knowledge.db');

if (!rag.canOpen(
  VectorStoreSpec(providerId: 'sqlite', location: location),
)) {
  throw UnsupportedError('SQLite RAG is unavailable on this platform');
}

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: location,
    filterSchema: FilterSchema(fields: [
      FilterField(name: 'topic', type: FilterFieldType.string),
    ]),
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge'),
);

await index.add(
  id: 'intro',
  document: EmbeddingInput.text('Flutter runs on six platforms.'),
  metadata: '{"topic":"flutter"}',
);
final hits = await index.search(
  query: EmbeddingInput.text('Where does Flutter run?'),
  filter: Filter(
    must: [FieldEquals(key: 'topic', value: 'flutter')],
  ),
);
await index.flush();
await index.dispose();
```

`location` is an absolute path on native — a database file for SQLite, a
directory for Qdrant; build it from `getApplicationDocumentsDirectory()` — and a
plain name on Web.

`add` embeds with the embedder's document role and stores the text as the
hit's `content`; `search` embeds with its query role. Every field a `Filter`
names must be declared in `filterSchema` — an undeclared one throws
`ArgumentError`. Every error of a `Future`-returning `RagIndex` or
`FlutterEdgeAiRag` method arrives as a failed future.

Chunk text below the embedder's input limit,
`(await FlutterEdgeAi.getActiveEmbedder()).maxInputTokens` (task prefix, BOS
and EOS included; 1024 for EmbeddingGemma 2, where chunks of 512 tokens or
fewer are recommended). A longer chunk or query is never truncated: `add` and
`search` throw `EmbeddingInputTooLongException`.

## Embedding profiles

One location belongs to one embedding space, named by an `EmbeddingProfile`.
The store persists that binding beside the vectors and refuses to overwrite
it, so mixing vectors of two models stays impossible after an app restart —
even when their dimensions match, as EmbeddingGemma 1 and 2 (both 768) do.

`FlutterEdgeAiActiveEmbedder` borrows the model returned by
`FlutterEdgeAi.getActiveEmbedder()`; this package never closes it. It pins the
embedding model that is active when it is created and resolves the model
again on every operation, so it follows core's embedder cache; after switching
embedders it throws `StateError` — create a new embedder and open a new index
at a new location. A request that failed because core replaced the model
before it ran (`EmbedderClosedException`) is retried once.

- `FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'knowledge')` derives
  the profile id from the installed file names
  (`'<namespace>@<files joined by +>'`). Installing a model under other file
  names changes the id, and the old location then refuses to open. The id
  follows file NAMES, not bytes: install with revision-qualified `filename:`s
  so new weights under the same download name get a new id too.
- `FlutterEdgeAiActiveEmbedder(profileId: …)` takes an explicit id. Use a
  stable, versioned id that covers the weights and the tokenizer, pooling,
  normalization, and document/query prefix contract — a mutable file path or
  download URL is not a content identity. Profile ids may not contain control
  characters (U+0000–U+001F).

Queries over text documents use `TaskType.retrievalQuery`; pass `queryTask:`
for another task, e.g. `TaskType.questionAnswering`.

## Vector-only indexes

Pure `addVector` and `searchVector` workflows do not need an embedder, but a
new location needs the profile of the pipeline that produced the vectors:

```dart
final vectors = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: await ragLocation('vectors.db'),
  ),
  profile: EmbeddingProfile(
    id: 'embeddinggemma-300m-v1',
    dimension: 768,
  ),
);
```

`addVector` and `searchVector` also work on an index opened with an embedder.

## A custom embedder

An independent text pipeline supplies its own borrowed embedder. It maps the
document and query roles to its model's conventions:

```dart
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);

  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> resolveProfile() async => EmbeddingProfile(
    id: 'my-embedder-weights-tokenizer-pooling-prefix-v1',
    dimension: 384,
  );

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) =>
      model.embed(document.text!, prefix: 'document: ');

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) => model.embed(query.text!, prefix: 'query: ');
}

final customIndex = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: await ragLocation('custom-v1.db'),
  ),
  embedder: AppEmbedder(myEmbeddingModel),
);
```

## Image and audio documents

A location holds documents of one modality, declared in
`VectorStoreSpec.documents` (text by default) and persisted with the profile.
An image or audio index needs an embedder whose `modalities` include it —
`open()` refuses one that does not with `ArgumentError`. Its `content` is
required and is a reference to the media (a URI, file path or asset id), never
its bytes; search results return it. A text query over an image index is
text-to-image search:

```dart
final photos = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: await ragLocation('photos-v1.db'),
    documents: EmbeddingModality.image,
  ),
  embedder: FlutterEdgeAiActiveEmbedder.forActiveModel(
    namespace: 'photos',
    supportImage: true,
  ),
);
await photos.add(
  id: 'photo-1',
  document: EmbeddingInput.image(jpegBytes),
  content: 'content://media/external/images/1',
);
final matches = await photos.search(
  query: EmbeddingInput.text('a red bicycle'),
);
```

`FlutterEdgeAiActiveEmbedder` and `.forActiveModel` take `supportImage:` and
`supportAudio:` for the media the active embedder must embed. EmbeddingGemma 2
embeds images with its 440m and 740m bundles and audio with the 740m; on a
bundle without that encoder `open()` fails with `EmbeddingLoadException`. A
custom `RagEmbedder` can embed media with any other model. Cross-modal scores
are not on one scale: mixed corpora use one index per modality, and the app
merges results.

## Existing stores

Stores written by flutter_edge_ai_rag 1.0 (`flutter_edge_ai_sqlite` /
`flutter_edge_ai_qdrant` 2.0.x) open unchanged as text locations, and text
locations still open with those versions. A location bound to images or audio
is refused by every older version.

An existing nonempty database without profile metadata (written before 2.0)
is treated as legacy and is never adopted silently. Migration requires the
caller to attest the model identity explicitly; the package also verifies its
dimension. Adoption applies to text locations only:

```dart
final migrated = await rag.openVectors(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: await ragLocation('legacy.db'),
    allowLegacyProfileAdoption: true,
  ),
  profile: knownLegacyProfile,
);
```

## Ownership and durability

`RagIndex` owns and closes its vector store. The embedder is always borrowed.
Normal reads and writes may overlap; `flush`, `clear`, and `dispose` are
exclusive barriers. Dispose rejects new work immediately and waits for work
already accepted by the index. `clear()` removes documents but intentionally
keeps the persistent binding: one location remains one embedding space and one
document modality for its lifetime.

Keep one app-owned index per location. On Web, SQLite enforces that rule with
an exclusive Web Lock, so make `open()` single-flight and share the returned
future rather than opening from multiple widgets. At shutdown, dispose every
`RagIndex` first, then call `FlutterEdgeAi.dispose()` or dispose a custom
embedder that the indexes borrowed.

## Implementing a vector store

A store is a `VectorStoreProvider` plus a class that
`extends VectorStoreRepository` (an `abstract base class`). Besides documents
and search it persists one `VectorStoreBinding` — the `EmbeddingProfile` and
the document modality — through `readBinding()` and `bind(binding)`. `bind` is
a durable compare-and-set: binding the same value again is a no-op, and any
difference throws `VectorStoreException`.

The binding is stored so that every version, old and new, reads it safely:

- A **version-1 profile record** `(id, dimension)` is always written; it is the
  record rag 1.0 stores read and write, and the compare-and-set point for
  every version. Its id is `VectorStoreBinding.v1RecordId`: the profile id for
  a text binding, `'<profile id>\u001F<modality>'` for an image or audio one.
  Profile ids cannot contain U+001F, so a qualified id never equals an id an
  older version is asked to open, and every older reader refuses the location.
- An image or audio binding also writes a **version-2 record**
  `(unqualified profile id, dimension, documents)`, cross-checked against the
  version-1 record on every read. `VectorStoreBinding.fromV1Record` decodes the
  version-1 id.

| v1 record | v2 record | binding |
|---|---|---|
| absent | absent | unbound (`null`) |
| absent | present | corrupt |
| unqualified id | absent | text |
| unqualified id | present | corrupt |
| qualified id | present, agreeing | image / audio |
| qualified id | present, disagreeing | corrupt |
| qualified id | absent | corrupt, unless the store publishes the two records separately and can republish v2 from v1 |
| qualified id, unknown modality | any | written by a newer version |

"Corrupt" and "newer version" are `VectorStoreException`s. The
`VectorStoreBinding` dartdoc carries the same table and the one accepted limit
of the encoding.
