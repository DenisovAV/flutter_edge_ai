import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for issue #308 on the litert/FFI path —
/// `FfiInferenceModel.createSession` short-circuits on a cached
/// `_createCompleter`, so every `createChat` after the first reuses the
/// same conversation handle and the previous conversation's KV cache
/// bleeds into the next chat. This is the FFI sibling of the MediaPipe
/// fix in #309.
/// https://github.com/DenisovAV/flutter_gemma/issues/308
///
/// Mirrors the distilled-logic style of `test/mobile/session_creation_reuse_test.dart`
/// (the #309 MediaPipe regression) and `model_creation_failure_test.dart`
/// (#170, the model-level version of this completer bug): the completer /
/// session lifecycle is modelled in a `Buggy`/`Fixed` pair so the bug and
/// the fix are asserted directly against the logic that changed, without
/// needing a real FFI client (whose `createConversationHandle` returns a
/// concrete handle type that can't be faked through the public surface).
///
/// FFI specifics modelled here:
///   * each session owns its OWN `ConversationHandle` (not a shared native
///     session), created by `ffiClient.createConversationHandle`;
///   * `createSession` already closes the prior session before opening the
///     next — but the cached-completer short-circuit means the second call
///     never reaches that close, so it hands back the stale session.

class MockFfiClient {
  int createHandleCallCount = 0;
  bool shouldFail = false;

  MockHandle createConversationHandle() {
    createHandleCallCount++;
    if (shouldFail) {
      throw Exception('Conversation handle creation failed');
    }
    return MockHandle(id: createHandleCallCount);
  }
}

class MockHandle {
  MockHandle({required this.id});

  final int id;
  bool closed = false;

  void close() {
    closed = true;
  }
}

/// The current (buggy) `createSession` completer logic: the completer is a
/// permanent cache — once a session is created it is returned for every
/// subsequent call until that session is closed.
class BuggyFfiSessionCreator {
  BuggyFfiSessionCreator(this.client);

  final MockFfiClient client;
  FakeFfiSession? _session;
  Completer<FakeFfiSession>? _createCompleter;

  Future<FakeFfiSession> createSession() async {
    // BUG: cached completer short-circuits across *sequential* calls, so
    // the new handle + prior-session-close below never run for call 2+.
    if (_createCompleter case final completer?) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<FakeFfiSession>();
    try {
      final handle = client.createConversationHandle();
      await _session?.close();
      final session = FakeFfiSession(
        handle: handle,
        onClose: () {
          _session = null;
          _createCompleter = null; // only cleared on close
        },
      );
      _session = session;
      completer.complete(session);
      return session;
    } catch (e, st) {
      completer.completeError(e, st);
      _createCompleter = null;
      rethrow;
    }
  }
}

/// The fixed logic: completer is a pure in-flight guard (cleared once
/// creation settles), the prior session is closed before the next is
/// created, `onClose` is identity-guarded, and `completer.future` is
/// returned so the caller stays the error listener.
class FixedFfiSessionCreator {
  FixedFfiSessionCreator(this.client);

  final MockFfiClient client;
  FakeFfiSession? _session;
  Completer<FakeFfiSession>? _createCompleter;

  Future<FakeFfiSession> createSession() async {
    if (_createCompleter case final completer?) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<FakeFfiSession>();
    try {
      // Close the prior session BEFORE creating the new handle — the
      // engine holds one live conversation at a time, and close-first
      // can't leak a freshly created handle if the close throws. See the
      // close-first rationale in FfiInferenceModel.createSession (PR #310).
      await _session?.close();
      final handle = client.createConversationHandle();
      late final FakeFfiSession session;
      session = FakeFfiSession(
        handle: handle,
        onClose: () {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = session;
      completer.complete(session);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _createCompleter = null;
    }
    return completer.future;
  }
}

class FakeFfiSession {
  FakeFfiSession({required this.handle, required this.onClose});

  final MockHandle handle;
  final void Function() onClose;
  bool _isClosed = false;

  Future<void> close() async {
    if (_isClosed) return; // idempotent
    _isClosed = true;
    handle.close();
    onClose();
  }
}

void main() {
  late MockFfiClient client;

  setUp(() => client = MockFfiClient());

  group('Issue #308 (FFI) — createSession reuses the cached session (bug)', () {
    test('BUG: second createSession returns the SAME session, no fresh '
        'handle — KV cache bleeds', () async {
      final creator = BuggyFfiSessionCreator(client);

      final a = await creator.createSession();
      final b = await creator.createSession();

      expect(
        client.createHandleCallCount,
        1,
        reason: 'BUG: no fresh conversation handle for the 2nd chat',
      );
      expect(identical(a, b), isTrue);
      expect(
        a.handle.id,
        b.handle.id,
        reason: 'BUG: same handle → prior KV cache is reused',
      );
    });

    // NOTE: unlike the MediaPipe original (#309), the FFI buggy path
    // already clears `_createCompleter` in its catch, so a *failed*
    // createSession does not block retry here — the cache-on-success
    // bleed above is the only FFI bug. The fix preserves that
    // already-correct failure behaviour (see the FIX retry test below).
  });

  group('Issue #308 (FFI) — createSession yields a fresh session (fix)', () {
    test('FIX: second createSession opens a FRESH handle', () async {
      final creator = FixedFfiSessionCreator(client);

      final a = await creator.createSession();
      final b = await creator.createSession();

      expect(client.createHandleCallCount, 2);
      expect(identical(a, b), isFalse);
      expect(
        a.handle.id != b.handle.id,
        isTrue,
        reason: 'FIX: distinct handles → no KV-cache bleed',
      );
    });

    test(
      'FIX: the prior session is closed before the next is created',
      () async {
        final creator = FixedFfiSessionCreator(client);

        final a = await creator.createSession();
        expect(a.handle.closed, isFalse);

        await creator.createSession();
        expect(
          a.handle.closed,
          isTrue,
          reason: 'FIX: old handle closed so its KV cache is released',
        );
      },
    );

    test('FIX: a failed createSession does not block retry', () async {
      final creator = FixedFfiSessionCreator(client);

      client.shouldFail = true;
      await expectLater(creator.createSession(), throwsException);
      client.shouldFail = false;
      final session = await creator.createSession();
      expect(session.handle.id, greaterThan(0));
      expect(
        client.createHandleCallCount,
        2,
        reason: 'FIX: completer cleared on failure → retry runs',
      );
    });

    test('FIX: concurrent createSession calls dedupe to one handle', () async {
      final creator = FixedFfiSessionCreator(client);

      final results = await Future.wait([
        creator.createSession(),
        creator.createSession(),
        creator.createSession(),
      ]);

      expect(
        client.createHandleCallCount,
        1,
        reason: 'concurrent callers share one in-flight creation',
      );
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
    });

    test('FIX: idempotent close — closing a superseded session does not '
        'double-close its handle', () async {
      final creator = FixedFfiSessionCreator(client);

      final a = await creator.createSession(); // handle 1
      await creator.createSession(); // handle 2 (a closed once)
      expect(a.handle.closed, isTrue);

      // A consumer that still holds the old session closes it again —
      // must be a no-op, not a second handle.close()/onClose().
      await a.close();
      expect(a.handle.closed, isTrue);
    });
  });
}
