import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for issue #308 — `MobileInferenceModel.createSession`
/// short-circuits on a cached `_createCompleter`, so every `createChat`
/// after the first reuses the same native session and the previous
/// conversation's KV cache bleeds into the next chat.
/// https://github.com/DenisovAV/flutter_gemma/issues/308
///
/// Mirrors the distilled-logic style of `model_creation_failure_test.dart`
/// (issue #170, the model-level version of this same completer bug): rather
/// than spin up the pigeon platform channel + native engine, the completer /
/// session lifecycle is modelled in a `Buggy`/`Fixed` pair so the bug and
/// the fix are asserted directly against the logic that changed.
///
/// The native contract being modelled (`FlutterGemmaPlugin.createSession`):
///   session?.close();                       // close the prior session
///   session = engine.createSession(config); // create a fresh one
/// i.e. the native layer already gives every createSession a clean session.
/// The bug is purely Dart-side: the cached completer means native
/// createSession is never invoked the second time.

/// Models the native `PlatformService` session calls. `createSession`
/// closes any open native session and opens a fresh one (matching the
/// Kotlin `session?.close(); session = engine.createSession(...)`).
class MockPlatformService {
  int createSessionCallCount = 0;
  int closeSessionCallCount = 0;

  /// Monotonic id of the currently-open native session, or 0 when none.
  int activeNativeSessionId = 0;
  int _nextNativeSessionId = 0;
  bool shouldFail = false;

  Future<void> createSession() async {
    createSessionCallCount++;
    if (shouldFail) {
      throw Exception('Session creation failed');
    }
    // Native side closes the prior session and opens a new one.
    activeNativeSessionId = ++_nextNativeSessionId;
  }

  Future<void> closeSession() async {
    closeSessionCallCount++;
    activeNativeSessionId = 0;
  }

  void reset() {
    createSessionCallCount = 0;
    closeSessionCallCount = 0;
    activeNativeSessionId = 0;
    _nextNativeSessionId = 0;
    shouldFail = false;
  }
}

/// A session wrapper that records which native session it was created
/// against, so a test can assert "this wrapper's calls hit native session
/// N" — the property KV-cache isolation depends on.
class MockSession {
  MockSession({
    required this.platform,
    required this.nativeSessionId,
    required this.onClose,
  });

  final MockPlatformService platform;
  final int nativeSessionId;
  final void Function(MockSession session) onClose;
  bool isClosed = false;

  Future<void> close({bool idempotent = false}) async {
    if (idempotent && isClosed) return;
    isClosed = true;
    onClose(this);
    await platform.closeSession();
  }
}

/// The current (buggy) `createSession` completer logic: the completer is a
/// permanent cache — once a session is created it is returned for every
/// subsequent call until that session is closed.
class BuggySessionCreator {
  BuggySessionCreator(this.platform);

  final MockPlatformService platform;
  Completer<MockSession>? _createCompleter;

  Future<MockSession> createSession() async {
    // BUG: cached completer short-circuits across *sequential* calls — and
    // is only ever cleared by the session's onClose, so it acts as a
    // permanent cache rather than an in-flight guard.
    if (_createCompleter case final completer?) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<MockSession>();
    try {
      await platform.createSession();
      final session = MockSession(
        platform: platform,
        nativeSessionId: platform.activeNativeSessionId,
        onClose: (_) {
          _createCompleter = null; // only cleared on close
        },
      );
      completer.complete(session);
      return session;
    } catch (e, st) {
      // BUG: completer not cleared on failure → permanent rejected cache.
      completer.completeError(e, st);
      rethrow;
    }
  }
}

/// The fixed `createSession` logic: the completer is a pure in-flight guard
/// (cleared once creation settles), the prior session is closed before the
/// next is created, and `onClose` is identity-guarded.
class FixedSessionCreator {
  FixedSessionCreator(this.platform);

  final MockPlatformService platform;
  MockSession? _session;
  Completer<MockSession>? _createCompleter;

  Future<MockSession> createSession() async {
    // In-flight guard for concurrent callers only.
    if (_createCompleter case final completer?) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<MockSession>();
    try {
      // Close any prior singleton session before creating the next.
      if (_session case final previous?) {
        await previous.close(idempotent: true);
      }
      await platform.createSession();
      late final MockSession session;
      session = MockSession(
        platform: platform,
        nativeSessionId: platform.activeNativeSessionId,
        onClose: (_) {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = session;
      completer.complete(session);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      // Pure in-flight guard: cleared on success OR failure.
      _createCompleter = null;
    }
    // Return the completer's future so the caller stays the error
    // listener even after the completer field is cleared (mirrors the
    // createModel idiom from issue #170).
    return completer.future;
  }
}

void main() {
  late MockPlatformService platform;

  setUp(() => platform = MockPlatformService());
  tearDown(() => platform.reset());

  group('Issue #308 — createSession reuses the cached session (bug)', () {
    test('BUG: second createSession returns the SAME session, native '
        'createSession never called again — KV cache bleeds', () async {
      final creator = BuggySessionCreator(platform);

      final a = await creator.createSession();
      final b = await creator.createSession();

      expect(
        platform.createSessionCallCount,
        1,
        reason: 'BUG: native createSession not called for the 2nd chat',
      );
      expect(
        identical(a, b),
        isTrue,
        reason: 'BUG: both chats share one session',
      );
      expect(
        a.nativeSessionId,
        b.nativeSessionId,
        reason: 'BUG: same native session → prior KV cache is reused',
      );
    });

    test('BUG: a failed createSession permanently caches the rejected '
        'future, blocking retry', () async {
      final creator = BuggySessionCreator(platform);

      platform.shouldFail = true;
      await expectLater(creator.createSession(), throwsException);

      platform.shouldFail = false;
      await expectLater(
        creator.createSession(),
        throwsException,
        reason: 'BUG: cached rejected completer blocks the retry',
      );
      expect(
        platform.createSessionCallCount,
        1,
        reason: 'BUG: native createSession not retried',
      );
    });
  });

  group('Issue #308 — createSession yields a fresh session (fix)', () {
    test('FIX: second createSession creates a FRESH native session', () async {
      final creator = FixedSessionCreator(platform);

      final a = await creator.createSession();
      final b = await creator.createSession();

      expect(
        platform.createSessionCallCount,
        2,
        reason: 'FIX: native createSession runs for each chat',
      );
      expect(
        identical(a, b),
        isFalse,
        reason: 'FIX: each chat gets its own wrapper',
      );
      expect(
        a.nativeSessionId != b.nativeSessionId,
        isTrue,
        reason: 'FIX: distinct native sessions → no KV-cache bleed',
      );
    });

    test(
      'FIX: the prior session is closed before the next is created',
      () async {
        final creator = FixedSessionCreator(platform);

        final a = await creator.createSession();
        expect(a.isClosed, isFalse);

        await creator.createSession();
        expect(
          a.isClosed,
          isTrue,
          reason: 'FIX: old wrapper is closed so stray use throws cleanly',
        );
        expect(
          platform.closeSessionCallCount,
          1,
          reason: 'FIX: exactly one close for the superseded session',
        );
      },
    );

    test('FIX: a failed createSession does not block retry', () async {
      final creator = FixedSessionCreator(platform);

      platform.shouldFail = true;
      await expectLater(creator.createSession(), throwsException);

      platform.shouldFail = false;
      final session = await creator.createSession();
      expect(session.nativeSessionId, greaterThan(0));
      expect(
        platform.createSessionCallCount,
        2,
        reason: 'FIX: completer cleared on failure → retry runs',
      );
    });

    test('FIX: concurrent createSession calls still dedupe to one native '
        'session (in-flight guard preserved)', () async {
      final creator = FixedSessionCreator(platform);

      final results = await Future.wait([
        creator.createSession(),
        creator.createSession(),
        creator.createSession(),
      ]);

      expect(
        platform.createSessionCallCount,
        1,
        reason: 'concurrent callers share one in-flight creation',
      );
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
    });

    test('FIX: idempotent close — closing a superseded session does NOT '
        'tear down the current native session', () async {
      final creator = FixedSessionCreator(platform);

      final a = await creator.createSession(); // native session 1
      final b = await creator.createSession(); // native session 2 (a closed)

      expect(a.isClosed, isTrue);
      expect(b.isClosed, isFalse);
      final closesAfterSupersede = platform.closeSessionCallCount;

      // A consumer that still holds the old chat closes it. Idempotent
      // close must NOT call native closeSession again (which would close
      // session 2, since closeSession is argument-less).
      await a.close(idempotent: true);

      expect(
        platform.closeSessionCallCount,
        closesAfterSupersede,
        reason: 'idempotent close on the stale wrapper is a no-op',
      );
      expect(b.isClosed, isFalse, reason: 'the current session stays open');
    });
  });
}
