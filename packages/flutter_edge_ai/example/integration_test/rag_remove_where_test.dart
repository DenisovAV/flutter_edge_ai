// RagIndex.removeWhere on a device, through the app's own native libraries:
// the vec0 loadable and the qdrant-edge library each platform ships. The
// shared parity table holds the filter semantics; this suite shows they are
// the same on the device as on the host.
//
// Run: flutter test integration_test/rag_remove_where_test.dart -d <device>
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ignore: implementation_imports — shares the sqlite package's parity cases
import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart' as parity;

final _profile = EmbeddingProfile(id: 'device-remove-where-v1', dimension: 4);

Future<String> _location(String name) async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}/'
    'rw_${name}_${DateTime.now().microsecondsSinceEpoch}',
  );
  await dir.create(recursive: true);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir.path;
}

/// The two stores, each with what its location needs: a file for SQLite,
/// a directory for qdrant.
final _stores = <String, (VectorStoreProvider, String Function(String))>{
  'sqlite': (const SqliteVectorStoreProvider(), (dir) => '$dir/rag.db'),
  'qdrant': (const QdrantVectorStoreProvider(), (dir) => dir),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final MapEntry(key: name, value: (provider, path)) in _stores.entries) {
    Future<RagIndex> open(String location, FilterSchema schema) =>
        FlutterEdgeAiRag(providers: [provider]).openVectors(
          spec: VectorStoreSpec(
            providerId: provider.id,
            location: location,
            filterSchema: schema,
            enableTextSearch: true,
          ),
          profile: _profile,
        );

    testWidgets('$name: the shared parity table holds for removeWhere', (
      tester,
    ) async {
      expect(parity.cases, hasLength(20));
      var refused = 0;
      for (final c in parity.cases) {
        final index = await open(
          path(await _location('${name}_parity')),
          parity.schema,
        );
        for (final d in parity.docs) {
          await index.addVector(
            id: d.id,
            content: 'shared ${d.id}',
            embedding: parity.embedding,
            metadata: d.metadata,
          );
        }
        final f = c.filter;
        final undeclared = [
          ...?f.must,
          ...?f.should,
          ...?f.mustNot,
        ].any((condition) => parity.schema.fieldFor(condition.key) == null);
        if (undeclared) {
          // Through RagIndex an undeclared field is refused, not ignored as
          // the store does when called directly; nothing is removed.
          await expectLater(index.removeWhere(f), throwsArgumentError);
          expect(
            (await index.stats()).documentCount,
            parity.docs.length,
            reason: c.name,
          );
          refused++;
          await index.dispose();
          continue;
        }
        final kept = [
          for (final d in parity.docs)
            if (!c.expected.contains(d.id)) d.id,
        ]..sort();
        expect(
          await index.removeWhere(c.filter),
          c.expected.length,
          reason: c.name,
        );
        final vector = await index.searchVector(
          embedding: parity.embedding,
          topK: parity.docs.length,
          threshold: -1,
        );
        expect([for (final r in vector) r.id]..sort(), kept, reason: c.name);
        final text = await index.searchText(
          text: 'shared',
          topK: parity.docs.length,
        );
        expect([for (final r in text) r.id]..sort(), kept, reason: c.name);
        await index.dispose();
      }
      expect(refused, 2, reason: 'the two undeclared-key cases');
    }, timeout: const Timeout(Duration(minutes: 4)));

    testWidgets('$name: removes one file and survives reopen', (tester) async {
      final schema = FilterSchema(
        fields: [FilterField(name: 'source', type: FilterFieldType.string)],
      );
      final location = path(await _location('${name}_file'));
      final first = await open(location, schema);
      for (final (id, source) in [
        ('a1', 'a.md'),
        ('a2', 'a.md'),
        ('a3', 'a.md'),
        ('b1', 'b.md'),
      ]) {
        await first.addVector(
          id: id,
          content: 'chunk $id about rivers',
          embedding: const [1, 0, 0, 0],
          metadata: jsonEncode({'source': source}),
        );
      }
      final aMd = Filter(
        must: [FieldEquals(key: 'source', value: 'a.md')],
      );
      expect(await first.removeWhere(aMd), 3);
      await first.flush();
      await first.dispose();

      final second = await open(location, schema);
      addTearDown(second.dispose);
      expect((await second.stats()).documentCount, 1);
      expect(
        [for (final r in await second.searchText(text: 'rivers')) r.id],
        ['b1'],
      );
      expect(await second.removeWhere(aMd), 0);
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
