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
}
