// The provider over the real libany_shim (ABI 2) and its isolates: one
// device, p2p off, the dead nodeconf. Skipped, with the reason, without an
// ABI-2 library (support/native_library.dart).
import 'dart:io';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_library.dart';
import 'support/parity_cases.dart' as parity;

final profile = EmbeddingProfile(id: 'native-test-v1', dimension: 4);

void main() {
  final skip = nativeSkipReason();
  late Directory tmp;
  late AnySyncAccount account;
  late AnySyncLocation loc;

  setUp(() async {
    if (skip != null) return;
    tmp = Directory.systemTemp.createTempSync('any_provider');
    account = await AnySyncAccount.open(
      dataDirectory: '${tmp.path}/sdk',
      indexDirectory: '${tmp.path}/index',
      mnemonic: await AnySyncAccount.newMnemonic(),
      deviceKey: await AnySyncAccount.newDeviceKey(),
      nodeConfYaml: deadNodeConf(),
      p2p: const AnySyncP2p.disabled(),
    );
    final space = await account.createSpace('native');
    loc = AnySyncLocation(spaceId: space.id, indexName: 'notes');
  });
  tearDown(() async {
    if (skip != null) return;
    await account.close();
    tmp.deleteSync(recursive: true);
  });

  RagIndexFuture open({FilterSchema? schema, bool text = false}) =>
      FlutterEdgeAiRag(
        providers: [AnyVectorStoreProvider(account)],
      ).openVectors(
        spec: VectorStoreSpec(
          providerId: AnyVectorStoreProvider.providerId,
          location: loc.value,
          filterSchema: schema ?? FilterSchema.empty,
          enableTextSearch: text,
        ),
        profile: profile,
      );

  test(
    'add, update, search, text, remove, clear, reopen',
    skip: skip,
    () async {
      final i = await open(text: true);
      await i.addVector(
        id: 'r',
        embedding: [1, 0, 0, 0],
        content: 'rocket fuel',
      );
      await i.addVector(id: 's', embedding: [0, 1, 0, 0], content: 'sourdough');
      await i.addVector(id: 'r', embedding: [1, 0, 0, 0], content: 'rocket v2');
      var hits = await i.searchVector(embedding: [1, 0, 0, 0], topK: 5);
      expect(hits.map((h) => h.id), ['r', 's']);
      expect(hits.first.content, 'rocket v2');
      expect((await i.searchText(text: 'sourdough')).map((h) => h.id), ['s']);
      final st = await account.locationStatus(loc);
      expect(st.documents, 2);
      expect(st.pendingSupersedeDeletes, 1, reason: 'alone: the old r waits');
      await i.remove(id: 's');
      expect(await i.searchText(text: 'sourdough'), isEmpty);
      await i.dispose();
      final again = await open();
      hits = await again.searchVector(embedding: [1, 0, 0, 0], topK: 5);
      expect(hits.map((h) => h.id), ['r']);
      await again.clear();
      expect((await again.stats()).documentCount, 0);
      await again.dispose();
    },
  );

  test('the parity table on any-store', skip: skip, () async {
    final store = await AnyVectorStoreProvider(
      account,
    ).createStore(VectorStoreSpec(providerId: 'any', location: loc.value));
    store.configure(parity.schema);
    await store.initialize(loc.value);
    await store.bind(VectorStoreBinding(profile: profile));
    for (final d in parity.docs) {
      await store.addDocument(
        id: d.id,
        content: d.id,
        embedding: parity.embedding,
        metadata: d.metadata,
      );
    }
    for (final c in parity.cases) {
      final hits = await store.searchSimilar(
        queryEmbedding: parity.embedding,
        topK: parity.docs.length,
        filter: c.filter,
      );
      expect(
        hits.map((h) => h.id).toList()..sort(),
        [...c.expected]..sort(),
        reason: c.name,
      );
    }
    await store.close();
  });

  test(
    'suspend closes the SDK, search goes on, resume reopens',
    skip: skip,
    () async {
      final i = await open();
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'x');
      expect(await account.suspend(), AnySyncAccountState.suspended);
      expect((await i.searchVector(embedding: [1, 0, 0, 0])).map((h) => h.id), [
        'x',
      ]);
      await expectLater(
        i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'y'),
        throwsA(isA<AnySyncSuspendedException>()),
      );
      expect(await account.resume(), AnySyncAccountState.open);
      await i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'y');
      await i.dispose();
    },
  );
}

typedef RagIndexFuture = Future<RagIndex>;
