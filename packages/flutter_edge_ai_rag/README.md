# Flutter Edge AI RAG

Pluggable, instance-scoped retrieval-augmented generation for
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai). The package owns
RAG orchestration and contracts; storage implementations are supplied by
separate packages such as `flutter_edge_ai_qdrant` and
`flutter_edge_ai_sqlite`.

```dart
final rag = FlutterEdgeAiRag(
  providers: [SqliteVectorStoreProvider()],
);

if (!rag.canOpen(
  VectorStoreSpec(providerId: 'sqlite', location: 'knowledge.db'),
)) {
  throw UnsupportedError('SQLite RAG is unavailable on this platform');
}

final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: 'knowledge.db',
    filterSchema: const FilterSchema(fields: [
      FilterField(name: 'topic', type: FilterFieldType.string),
    ]),
  ),
  activeEmbedderProfileId:
      'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
      'retrieval-prefix-meanpool-l2-v1',
);

await index.addText(
  id: 'intro',
  content: 'Flutter runs on six platforms.',
  metadata: '{"topic":"flutter"}',
);
final hits = await index.searchText(
  query: 'Where does Flutter run?',
  filter: const Filter(
    must: [FieldEquals(key: 'topic', value: 'flutter')],
  ),
);
await index.flush();
await index.dispose();
```

The default embedder is borrowed lazily from
`FlutterEdgeAi.getActiveEmbedder()`. This package never closes that core-owned
model. Its `activeEmbedderProfileId` is explicit because a mutable file path or
download URL is not a content identity. Use a stable, versioned ID that covers
the weights and the tokenizer, pooling, normalization, and document/query
prefix contract that define the embedding space. Without that ID, vector-only
use of an already-bound store remains available, but the first text operation
fails instead of inventing an identity.

Pass a custom `RagEmbedder` to `open()` when RAG must be initialized
independently from the main Flutter Edge AI runtime. Pure `addVector` and
`searchVector` workflows do not resolve an embedder at all, but they require an
explicit profile when a new location is opened:

```dart
final vectors = await rag.open(
  spec: VectorStoreSpec(providerId: 'sqlite', location: 'vectors.db'),
  embeddingProfile: EmbeddingProfile(
    id: 'embeddinggemma-300m-v1',
    dimension: 768,
  ),
);
```

An independent text pipeline supplies its own borrowed embedder:

```dart
class AppEmbedder implements RagEmbedder {
  AppEmbedder(this.model);

  final MyEmbeddingModel model;

  @override
  Future<EmbeddingProfile> get profile async => EmbeddingProfile(
    id: 'my-embedder-weights-tokenizer-pooling-prefix-v1',
    dimension: 384,
  );

  @override
  Future<List<double>> embedDocument(String text) =>
      model.embed(text, prefix: 'document: ');

  @override
  Future<List<double>> embedQuery(String text) =>
      model.embed(text, prefix: 'query: ');
}

final customIndex = await rag.open(
  spec: VectorStoreSpec(providerId: 'sqlite', location: 'custom-v1.db'),
  embedder: AppEmbedder(myEmbeddingModel),
);
```

One `RagIndex` pins one `EmbeddingProfile`. Use a different persistent
`location` for each embedding profile; mixing vectors from different models is
invalid even when their dimensions happen to match. Providers persist this
binding beside the vectors and refuse to overwrite it, so the same safety rule
survives app restarts. A vector operation on an unbound index fails until a
text operation binds its embedder or `embeddingProfile` is passed to `open()`.

An existing nonempty database without profile metadata is treated as legacy
and is never adopted silently. Migration requires the caller to attest the
model identity explicitly; the package also verifies its dimension:

```dart
final migrated = await rag.open(
  spec: VectorStoreSpec(
    providerId: 'sqlite',
    location: 'legacy.db',
    allowLegacyProfileAdoption: true,
  ),
  embeddingProfile: knownLegacyProfile,
);
```

`RagIndex` owns and closes its vector store. The embedder is always borrowed.
Normal reads and writes may overlap; `flush`, `clear`, and `dispose` are
exclusive barriers. Dispose rejects new work immediately and waits for work
already accepted by the index. `clear()` removes documents but intentionally
keeps the persistent profile binding: one location remains one embedding
space for its lifetime.

Keep one app-owned index per location. On Web, SQLite enforces that rule with
an exclusive Web Lock, so make `open()` single-flight and share the returned
future rather than opening from multiple widgets. At shutdown, dispose every
`RagIndex` first, then call `FlutterEdgeAi.dispose()` or dispose a custom
embedder that the indexes borrowed.
