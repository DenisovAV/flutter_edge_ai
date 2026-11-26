// The web Session's lifecycle over the stub `@litert-lm/core`
// (web_runtime_stub.dart): a session or a clone the runtime finishes after
// the engine's close began is deleted and refused, and that close waits for
// it; generateContent is one hold of the page lock; a session's generation
// meets the engine's sampler latch (LiteRT-LM#2080); a close under a
// poisoned page lock still marks the session closed and lets the engine go
// of it.
//
// Run: dart test -p chrome test/web/web_session_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_session_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:litertlm_dart/src/runtime/types.dart' show Sampler;
import 'package:litertlm_dart/src/web/litert_lm_js.dart' show JsLiteRtLmSession;
import 'package:litertlm_dart/src/web/web_session.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

List<String> _ops() => [
  for (final op in (page['ops'] as JSArray<JSAny?>?)?.toDart ?? const [])
    (op as JSString).toDart,
];

final class _Owner implements WebSessionOwner {
  @override
  final sessions = <WebSessionHandle>{};

  @override
  bool closed = false;

  @override
  Future<T> pendingCreate<T>(Future<T> Function() body) => body();

  @override
  void noteGeneration(Sampler sampling, {required bool explicit}) {}

  @override
  String incompleteRuntime(String what, List<String> missing) =>
      '$what lacks $missing';
}

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  test('a session the runtime makes while the engine closes is deleted and '
      'refused, and the close waits for it', () async {
    final engine = await webEngine();
    setOnPage('holdSession', true);
    final session = engine.createSession();
    final refused = expectLater(
      session,
      throwsWith<StateError>('closed while a session opened'),
    );
    await settle();
    var closed = false;
    final closing = engine.close().then((_) => closed = true);
    await settle();
    expect(closed, isFalse, reason: 'the close waits for the create');
    js('__releaseHeld');
    await refused;
    await closing;
    expect(page['sessionDeletes'].dartify(), 1);
  });

  test('a clone the runtime makes while the engine closes is deleted and '
      'refused, and the close waits for it', () async {
    final engine = await webEngine();
    final session = await engine.createSession();
    setOnPage('holdClone', true);
    final clone = session.clone();
    final refused = expectLater(
      clone,
      throwsWith<StateError>('closed while a session opened'),
    );
    await settle();
    var closed = false;
    final closing = engine.close().then((_) => closed = true);
    await settle();
    expect(closed, isFalse, reason: 'the close waits for the clone');
    js('__releaseHeld');
    await refused;
    await closing;
    // The session, by the engine's close, and the refused clone.
    expect(page['sessionDeletes'].dartify(), 2);
  });

  test('generateContent holds the page lock from its prefill to its decode: '
      'another call waits for both', () async {
    final engine = await webEngine();
    final a = await engine.createSession();
    final b = await engine.createSession();
    setOnPage('holdPrefill', true);
    final generated = a.generateContent([const InputData.text('2 + 2?')]);
    await settle();
    final other = b.runPrefill([const InputData.text('3 + 3?')]);
    await settle();
    js('__releaseHeld');
    expect(await generated, 'decoded 1');
    await other;
    expect(_ops(), ['prefill', 'decode', 'prefill']);
    await engine.close();
  });

  test(
    "a session's decode is a generation of the engine: another caller's "
    'sampler after the first is warned about once (LiteRT-LM#2080)',
    () async {
      final engine = await webEngine();
      final printed = await printsOf(() async {
        final first = await engine.createSession(
          SessionConfig(
            samplerConfig: SamplerConfig(topK: 1, topP: 1, temperature: 1),
          ),
        );
        await first.generateContent([const InputData.text('a')]);
        final second = await engine.createSession(
          SessionConfig(
            samplerConfig: SamplerConfig(topK: 40, topP: 0.9, temperature: 0.7),
          ),
        );
        await second.generateContent([const InputData.text('b')]);
        await second.runDecode();
      });
      expect(printed.where((l) => l.contains('LiteRT-LM#2080')), hasLength(1));
      await engine.close();
    },
  );

  test('a close under a poisoned page lock marks the session closed and '
      'leaves the owner\'s sessions; the poison is the error', () async {
    final lock = web.LiteRtLmPageLock();
    final owner = _Owner();
    final js =
        globalContext.callMethod<JSObject>(
              'eval'.toJS,
              '({runPrefill() {}, runDecode() {}, cancel() {}, clone() {}, '
                      'delete() {}})'
                  .toJS,
            )
            as JsLiteRtLmSession;
    final handle = await WebSessionHandle.adopt(
      js,
      lock,
      owner,
      sampling: const Sampler(temperature: 1, topK: 1, topP: 1, randomSeed: 0),
      explicitSampler: false,
    );
    expect(owner.sessions, {handle});
    lock.poisonFor(await lock.acquire(), 'A test held the page.');
    await expectLater(
      handle.close(),
      throwsA(isA<web.LiteRtLmPagePoisonedError>()),
    );
    expect(owner.sessions, isEmpty);
  });

  test("an engine's close cancels a session's decode in flight instead of "
      'waiting for its end', () async {
    final engine = await webEngine();
    final session = await engine.createSession();
    setOnPage('holdDecodeUntilCancel', true);
    final generated = session.generateContent([const InputData.text('go')]);
    await settle();
    expect(page['sessionCancels'].dartify(), isNull);
    final stoppedByClose = expectLater(
      generated,
      throwsWith<StateError>('closed while the call ran'),
    );
    await engine.close().timeout(const Duration(seconds: 5));
    expect(page['sessionCancels'].dartify(), 1);
    expect(page['sessionDeletes'].dartify(), 1);
    await stoppedByClose;
  });

  test("a caller's cancel ends a decode in flight with what it had, and a "
      'call queued behind another ends at once without running', () async {
    final engine = await webEngine();
    final a = await engine.createSession();
    setOnPage('holdDecodeUntilCancel', true);
    final generated = a.generateContent([const InputData.text('go')]);
    await settle();
    a.cancelProcess();
    // The stub's decode resolves with the one prefill it had.
    expect(await generated, 'decoded 1');

    final b = await engine.createSession();
    final c = await engine.createSession();
    setOnPage('holdPrefill', true);
    final held = b.runPrefill([const InputData.text('x')]);
    await settle();
    final queued = c.generateContent([const InputData.text('y')]);
    await settle();
    c.cancelProcess();
    js('__releaseHeld');
    await held;
    expect(await queued, '');
    expect(_ops(), ['prefill', 'decode', 'prefill']);
    await engine.close();
  });

  test('a cancel reaches the runtime session while its close waits for the '
      'page lock', () async {
    final engine = await webEngine();
    final a = await engine.createSession();
    final b = await engine.createSession();
    // b holds the page lock: a's close waits behind it.
    setOnPage('holdPrefill', true);
    final prefill = b.runPrefill([const InputData.text('x')]);
    await settle();
    final closing = engine.close();
    await settle();
    final before = page['sessionCancels'].dartify()! as num;
    a.cancelProcess();
    expect(page['sessionCancels'].dartify(), before + 1);
    js('__releaseHeld');
    await prefill.then((_) {}, onError: (_) {});
    await closing;
  });

  test('a Responses this release cannot read is deleted before the '
      'refusal', () async {
    final engine = await webEngine();
    final session = await engine.createSession();
    setOnPage('missingResponsesMember', 'getTexts');
    await expectLater(
      session.generateContent([const InputData.text('a')]),
      throwsWith<StateError>('getTexts'),
    );
    expect(page['responsesDeletes'].dartify(), 1);
    await engine.close();
  });

  test('a clone finished while its source closes is returned, usable and '
      'closable, as natively', () async {
    final engine = await webEngine();
    final a = await engine.createSession();
    await a.runPrefill([const InputData.text('x')]);
    setOnPage('holdClone', true);
    final cloning = a.clone();
    await settle();
    final closing = a.close();
    await settle();
    js('__releaseHeld');
    final clone = await cloning;
    await closing;
    expect(page['sessionDeletes'].dartify(), 1);
    expect(await clone.runDecode(), 'decoded 1');
    await clone.close();
    expect(page['sessionDeletes'].dartify(), 2);
    await engine.close();
    expect(page['sessionDeletes'].dartify(), 2);
  });

  test(
    "a close whose runtime cancel throws still deletes the session",
    () async {
      final engine = await webEngine();
      final a = await engine.createSession();
      setOnPage('throwingSessionCancel', true);
      await a.close();
      expect(page['sessionCancels'].dartify(), 1);
      expect(page['sessionDeletes'].dartify(), 1);
      await engine.close();
      expect(page['sessionDeletes'].dartify(), 1);
    },
  );

  test('a clone queued behind the page lock is refused once its session was '
      'cancelled, as natively', () async {
    final engine = await webEngine();
    final a = await engine.createSession();
    final b = await engine.createSession();
    setOnPage('holdPrefill', true);
    final held = b.runPrefill([const InputData.text('x')]);
    await settle();
    final cloning = a.clone();
    final refused = expectLater(
      cloning,
      throwsWith<StateError>('the session was cancelled'),
    );
    await settle();
    a.cancelProcess();
    js('__releaseHeld');
    await held;
    await refused;
    expect(_ops(), ['prefill']);
    await engine.close();
  });
}
