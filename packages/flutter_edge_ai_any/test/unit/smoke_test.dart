import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  test('add, search, remove, clear, reopen on one device', () async {
    final a = await w.open('a');
    final space = await a.createSpace('notes');
    final loc = AnySyncLocation(spaceId: space.id, indexName: 'notes');
    final index = await openVectors(a, loc);
    await index.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    await index.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'Y');
    final hits = await index.searchVector(embedding: [1, 0, 0, 0], topK: 2);
    expect(hits.map((h) => h.id), ['x', 'y']);
    expect(hits.first.content, 'X');
    await index.remove(id: 'x');
    expect(
      (await index.searchVector(
        embedding: [1, 0, 0, 0],
        topK: 2,
      )).map((h) => h.id),
      ['y'],
    );
    await index.clear();
    expect((await index.stats()).documentCount, 0);
    await index.addVector(id: 'z', embedding: [0, 0, 1, 0], content: 'Z');
    await index.dispose();
    final again = await openVectors(a, loc);
    expect((await again.stats()).documentCount, 1);
    await again.dispose();
  });
}
