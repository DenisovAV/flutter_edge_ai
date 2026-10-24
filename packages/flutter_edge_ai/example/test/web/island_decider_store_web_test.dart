// The web store of Tiny Island's fitted deciders: OPFS, one file per model.
// Model-free; run in a browser:
//   flutter test --platform chrome test/web/island_decider_store_web_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_edge_ai_example/tiny_island/island_decider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

const _model = 'embeddingGemma2Text270m';

Future<web.FileSystemDirectoryHandle> _root() =>
    web.window.navigator.storage.getDirectory().toDart;

/// Removes what earlier tests stored (created first, so removing never fails).
Future<void> _clear() async {
  final root = await _root();
  await root
      .getDirectoryHandle(
        'tiny_island_deciders',
        web.FileSystemGetDirectoryOptions(create: true),
      )
      .toDart;
  await root
      .removeEntry(
        'tiny_island_deciders',
        web.FileSystemRemoveOptions(recursive: true),
      )
      .toDart;
}

Future<void> _writeRaw(String text) async {
  final directory = await (await _root())
      .getDirectoryHandle(
        'tiny_island_deciders',
        web.FileSystemGetDirectoryOptions(create: true),
      )
      .toDart;
  final handle = await directory
      .getFileHandle('$_model.json', web.FileSystemGetFileOptions(create: true))
      .toDart;
  final writable = await handle.createWritable().toDart;
  await writable.write(text.toJS).toDart;
  await writable.close().toDart;
}

void main() {
  test('the web build gets the OPFS store', () {
    expect(createIslandDeciderStore().where, contains('OPFS'));
  });

  test('nothing stored reads as null', () async {
    await _clear();
    final store = createIslandDeciderStore();
    expect(await store.read(model: _model, fingerprint: 'a'), isNull);
  });

  test('a stored decider is read back for its fingerprint, and a newer '
      'catalog replaces it', () async {
    await _clear();
    final store = createIslandDeciderStore();
    final first = {
      'format': 'flutter_edge_ai.decider',
      'version': 1,
      'options': [
        {'id': 'walk_to(tree)', 'centroid': 'AAAA'},
      ],
    };
    expect(
      await store.write(model: _model, fingerprint: 'a', artifact: first),
      isNull,
    );
    expect(await store.read(model: _model, fingerprint: 'a'), first);
    expect(
      await store.read(model: _model, fingerprint: 'b'),
      isNull,
      reason: 'another fingerprint is another catalog',
    );
    // A fresh store (a new page load) reads what the first one wrote.
    expect(
      await createIslandDeciderStore().read(model: _model, fingerprint: 'a'),
      first,
    );

    final second = {...first, 'version': 2};
    await store.write(model: _model, fingerprint: 'b', artifact: second);
    expect(await store.read(model: _model, fingerprint: 'b'), second);
    expect(
      await store.read(model: _model, fingerprint: 'a'),
      isNull,
      reason: 'the older catalog\'s decider was replaced',
    );
  });

  test('a damaged file is a FormatException, and the next write replaces '
      'it', () async {
    await _clear();
    final store = createIslandDeciderStore();
    for (final damaged in ['not json', '{"fingerprint": 3}', '[1, 2]']) {
      await _writeRaw(damaged);
      await expectLater(
        store.read(model: _model, fingerprint: 'a'),
        throwsFormatException,
        reason: damaged,
      );
    }
    await store.write(model: _model, fingerprint: 'a', artifact: {'k': 1});
    expect(await store.read(model: _model, fingerprint: 'a'), {'k': 1});
  });
}
