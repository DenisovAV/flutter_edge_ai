// The small pieces the web arm relies on, each on its own: `awaitIfThenable`
// (a runtime's `delete()` is a Promise in the typings, but nothing relies on
// it), the once-per-page notes a release build shows (a failed delete,
// another @litert-lm/core than the one measured), and an engine's close
// waiting for its pending `delete()`. Its own file: the notes are once per
// page, and each browser test file is its own page.
//
// Run: dart test -p chrome test/web/web_runtime_notes_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_runtime_notes_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

JSAny? _eval(String source) =>
    globalContext.callMethod<JSAny?>('eval'.toJS, source.toJS);

void main() {
  group('awaitIfThenable', () {
    test('undefined completes at once', () async {
      await web.awaitIfThenable(_eval('undefined'));
    });

    test('an object without then completes at once', () async {
      await web.awaitIfThenable(_eval('({done: true})'));
    });

    test('a pending thenable is waited for', () async {
      _eval('window.__resolve = null');
      final pending = _eval(
        'new Promise((resolve) => { window.__resolve = resolve; })',
      );
      var done = false;
      final awaited = web.awaitIfThenable(pending).then((_) => done = true);
      await settle();

      expect(done, isFalse);
      _eval('window.__resolve()');
      await awaited;
      expect(done, isTrue);
    });

    test('a rejecting thenable throws', () async {
      final rejected = _eval(
        '(() => { const p = Promise.reject(new Error("delete failed")); '
        'p.catch(() => {}); return p; })()',
      );

      await expectLater(web.awaitIfThenable(rejected), throwsA(anything));
    });
  });

  test('Engine.close waits for the runtime\'s pending delete()', () async {
    installRuntime();
    addTearDown(removeRuntime);
    final engine = await webEngine();
    _eval('''window.__deleted = false; window.__finishDelete = null;
      window.Engine.create = ((create) => async (s) => {
        const e = await create(s);
        e.delete = () => new Promise((resolve) => {
          window.__finishDelete = () => { window.__deleted = true; resolve(); };
        });
        return e;
      })(window.Engine.create);''');
    final waiting = await webEngine();
    var closed = false;
    final closing = waiting.close().then((_) => closed = true);
    await settle();

    expect(closed, isFalse);
    _eval('window.__finishDelete()');
    await closing;
    expect((globalContext['__deleted']! as JSBoolean).toDart, isTrue);
    await engine.close();
  });

  test(
    'a failed delete is printed once per page for each kind of object',
    () async {
      final printed = await printsOf(() async {
        web.noteWebDeleteFailure('An engine', StateError('busy'));
        web.noteWebDeleteFailure('An engine', StateError('busy'));
        web.noteWebDeleteFailure('A conversation', StateError('busy'));
      });

      expect(printed, hasLength(2));
      expect(printed.first, allOf(contains('WARNING'), contains('An engine')));
      expect(printed.last, contains('A conversation'));
    },
  );

  group('the @litert-lm/core versions the page fetched', () {
    setUp(() {
      _eval('''window.__realEntries = performance.getEntriesByType;
        Object.defineProperty(performance, 'getEntriesByType', {
          configurable: true,
          value: (type) => type !== 'resource' ? [] : [
            {name: 'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.20.0/+esm'},
            {name: 'https://example.com/app.js'},
          ],
        });''');
    });
    tearDown(() {
      _eval('''Object.defineProperty(performance, 'getEntriesByType', {
          configurable: true, value: window.__realEntries});''');
    });

    test('are read from the resource URLs', () {
      expect(web.liteRtLmWebFetchedVersions(), {'0.20.0'});
    });

    test('another than the pinned one is printed once per page', () async {
      final printed = await printsOf(() async {
        web.noteOtherWebRuntimeVersion();
        web.noteOtherWebRuntimeVersion();
      });

      expect(printed, hasLength(1));
      expect(
        printed.single,
        allOf(contains('0.20.0'), contains(web.liteRtLmWebRuntimeVersion)),
      );
    });
  });
}
