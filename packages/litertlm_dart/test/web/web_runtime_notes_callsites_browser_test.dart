// The once-per-page notes through the calls that make them: a failed delete
// when an engine closes, and another @litert-lm/core than the pinned one,
// said before Engine.create and named in its failure. Its own file: the notes
// are once per page, and each browser test file is its own page.
//
// Run: dart test -p chrome test/web/web_runtime_notes_callsites_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_runtime_notes_callsites_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

void _fetched(String version) => globalContext.callMethod(
  'eval'.toJS,
  '''Object.defineProperty(performance, 'getEntriesByType', {
      configurable: true,
      value: (type) => type !== 'resource' ? [] : [
        {name: 'https://cdn.jsdelivr.net/npm/@litert-lm/core@$version/+esm'},
      ],
    });'''
      .toJS,
);

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  test('an engine whose delete fails is printed when it closes', () async {
    final engine = await webEngine();
    setOnPage('deleteError', 'engine busy');

    final printed = await printsOf(engine.close);

    expect(
      printed.where((l) => l.contains('An engine failed to free')),
      hasLength(1),
    );
    expect(printed.last, contains('engine busy'));
  });

  test('a conversation missing a member, whose delete fails, is printed '
      'when it is refused', () async {
    final engine = await webEngine();
    setOnPage('missingMember', 'cancel');
    setOnPage('deleteError', 'conversation busy');

    final printed = await printsOf(
      () => engine.createConversation().then((_) {}, onError: (Object _) {}),
    );

    expect(
      printed.where(
        (l) => l.contains('An incomplete conversation failed to free'),
      ),
      hasLength(1),
    );
    setOnPage('deleteError', null);
    setOnPage('missingMember', null);
    await engine.close();
  });

  test('a conversation the runtime built while the engine closed, whose '
      'delete fails, is printed', () async {
    final engine = await webEngine();
    setOnPage('holdConversation', true);

    // The create's continuation prints, so it starts inside printsOf.
    final printed = await printsOf(() async {
      final create = engine.createConversation().then(
        (_) {},
        onError: (Object _) {},
      );
      await settle();
      final closing = engine.close().then((_) {}, onError: (Object _) {});
      setOnPage('deleteError', 'conversation busy');
      js('__releaseConversations');
      await create;
      await closing;
    });

    expect(
      printed.where(
        (l) =>
            l.contains('A conversation opened during the close failed to free'),
      ),
      hasLength(1),
    );
  });

  test('another @litert-lm/core is named in the create failure, with the '
      'module to import, and printed before the create', () async {
    _fetched('0.18.0');
    setOnPage('createError', 'Unsupported backend: 2');

    late Object error;
    final printed = await printsOf(() async {
      try {
        await Engine.create(webConfig());
      } catch (e) {
        error = e;
      }
    });

    expect(
      printed.where((l) => l.contains('loaded @litert-lm/core 0.18.0')),
      hasLength(1),
    );
    expect(
      error,
      isA<LiteRtLmEngineCreateException>().having(
        (e) => e.message,
        'message',
        allOf(
          contains("The page's @litert-lm/core 0.18.0 could not create"),
          contains('Unsupported backend: 2'),
          contains(web.liteRtLmWebModuleUrl),
        ),
      ),
    );
  });

  test('a page whose resources cannot be listed still gets the runtime\'s '
      'create failure', () async {
    globalContext.callMethod(
      'eval'.toJS,
      '''Object.defineProperty(performance, 'getEntriesByType', {
          configurable: true,
          value: () => { throw new Error('no entries'); },
        });'''
          .toJS,
    );
    setOnPage('createError', 'Out of memory');

    await expectLater(
      Engine.create(webConfig()),
      throwsA(
        isA<LiteRtLmEngineCreateException>().having(
          (e) => e.message,
          'message',
          contains('Out of memory'),
        ),
      ),
    );
  });
}
