// `Session` on the web: `@litert-lm/core` 0.20.0's `Session` (session.d.ts),
// text prefill and whole-reply decode, each call holding the page lock the
// LLM and EmbeddingGemma 2 share (page_lock.dart).

import 'dart:js_interop';

import '../api/session.dart';
import '../runtime/errors.dart' show LiteRtLmNativeException;
import '../runtime/types.dart' show Sampler;
import 'litert_lm_js.dart';
import 'page_lock.dart';
import 'web_runtime_version.dart';

/// The members of a runtime `Session` this release calls.
const webSessionMembers = [
  'runPrefill',
  'runDecode',
  'cancel',
  'clone',
  'delete',
];

/// The members of a session's `Responses` this release calls.
const webResponsesMembers = ['getTexts', 'delete'];

/// What a [WebSessionHandle] needs of the engine that made it: its open
/// sessions, whether its close has begun, the creates that close waits for,
/// and the sampler latch (LiteRT-LM #2080).
abstract interface class WebSessionOwner {
  /// The engine's open sessions; its close closes them.
  Set<WebSessionHandle> get sessions;

  /// Whether the engine's close has begun.
  bool get closed;

  /// Runs [body], a runtime call that makes a session, as a create the
  /// engine's close waits for.
  Future<T> pendingCreate<T>(Future<T> Function() body);

  /// Says what LiteRT-LM #2080 means for a generation of a session that
  /// asked for [sampling], set by the caller ([explicit]) or not.
  void noteGeneration(Sampler sampling, {required bool explicit});

  /// Why a runtime [what] lacking [missing] cannot be driven, with the line
  /// that loads the pinned runtime.
  String incompleteRuntime(String what, List<String> missing);
}

/// A [SessionHandle] over a runtime session.
final class WebSessionHandle implements SessionHandle {
  WebSessionHandle._(
    this._js,
    this._pageLock,
    this._owner, {
    required this._sampling,
    required this._explicitSampler,
  }) {
    _owner.sessions.add(this);
  }

  /// [js], made by the runtime for [owner], as a handle registered in the
  /// owner's sessions. Refused, and deleted, when it lacks a member this
  /// release calls or when the engine's close began while the runtime made
  /// it: nobody else would delete it.
  static Future<WebSessionHandle> adopt(
    JsLiteRtLmSession js,
    LiteRtLmPageLock pageLock,
    WebSessionOwner owner, {
    required Sampler sampling,
    required bool explicitSampler,
  }) async {
    final missing = liteRtLmWebObjectMissing(js, webSessionMembers);
    if (missing.isNotEmpty || owner.closed) {
      if (!missing.contains('delete')) {
        try {
          await awaitIfThenable(js.delete());
        } catch (e) {
          noteWebDeleteFailure('A session', e);
        }
      }
      if (missing.isNotEmpty) {
        throw StateError(owner.incompleteRuntime('Session', missing));
      }
      throw StateError('The engine was closed while a session opened.');
    }
    return WebSessionHandle._(
      js,
      pageLock,
      owner,
      sampling: sampling,
      explicitSampler: explicitSampler,
    );
  }

  final JsLiteRtLmSession _js;
  final LiteRtLmPageLock _pageLock;
  final WebSessionOwner _owner;
  final Sampler _sampling;
  final bool _explicitSampler;
  bool _closed = false;

  /// [cancelProcess] was called: a prefill or decode that has not reached
  /// the runtime yet ends at once without running, as natively. One in the
  /// runtime ends with the text decoded until the cancel: @litert-lm/core
  /// 0.20.0's `runDecode` resolves with it (recorded: 8-21 ms after the
  /// cancel, example/integration_test/web_litertlm_runtime_probe_test.dart).
  bool _cancelRequested = false;

  /// The runtime session was deleted (or left to a poisoned page): a cancel
  /// no longer reaches it. Until then, also while [close] waits for the page
  /// lock, it does.
  bool _deleted = false;

  static JSArray<JSString> _texts(List<InputData> inputs) => [
    for (final input in inputs)
      switch (input) {
        TextInputData(:final text) => text.toJS,
        _ => throw UnsupportedError(
          "The web runtime ($liteRtLmWebRuntime) Session prefills text only: "
          "its runPrefill takes strings.",
        ),
      },
  ].toJS;

  /// Runs [body] holding the page lock: one operation of the page's module.
  ///
  /// A prefill or decode ([stopped]) ends as natively: cancelled by its
  /// caller before it got the lock, it returns [stopped] without running;
  /// cancelled while it ran, with what the runtime returned (or [stopped]
  /// when the runtime refused it). One that the session's or the engine's
  /// close stopped is a [StateError]. Any other call (a clone) is refused
  /// with a [StateError] once the session was cancelled, as natively, and
  /// returns what it made when the session closed while it ran.
  Future<T> _call<T>(
    String what,
    Future<T> Function() body, {
    T Function()? stopped,
  }) => _pageLock.run(() async {
    if (_closed) throw StateError('The session is closed.');
    if (_cancelRequested) {
      if (stopped != null) return stopped();
      throw StateError('$what: the session was cancelled.');
    }
    T result;
    try {
      result = await body();
    } on StateError {
      rethrow;
    } catch (e) {
      if (stopped != null && _cancelRequested) return stopped();
      if (_closed) throw _closedWhileRunning();
      throw LiteRtLmNativeException('$liteRtLmWebRuntime $what: $e');
    }
    if (stopped != null && _closed && !_cancelRequested) {
      throw _closedWhileRunning();
    }
    return result;
  });

  static StateError _closedWhileRunning() => StateError(
    'The session or its engine was closed while the call ran: the call was '
    'stopped and the session deleted.',
  );

  Future<void> _prefill(JSArray<JSString> texts) =>
      _js.runPrefill(texts).toDart;

  /// The decode, while the caller holds the page lock: the first candidate's
  /// text. Each is a generation of the engine, for LiteRT-LM #2080.
  Future<String> _decode() async {
    _owner.noteGeneration(_sampling, explicit: _explicitSampler);
    final responses = await _js.runDecode().toDart;
    final missing = liteRtLmWebObjectMissing(responses, webResponsesMembers);
    try {
      if (missing.isNotEmpty) {
        throw StateError(_owner.incompleteRuntime('Responses', missing));
      }
      final texts = responses.getTexts().toDart;
      return texts.isEmpty ? '' : texts.first.toDart;
    } finally {
      // Deleted also when refused, if it can be: nobody else would.
      if (!missing.contains('delete')) responses.delete();
    }
  }

  @override
  Future<void> runPrefill(List<InputData> inputs) async {
    final texts = _texts(inputs);
    await _call('refused the prefill', () => _prefill(texts), stopped: () {});
  }

  @override
  Future<String> runDecode() =>
      _call('refused the decode', _decode, stopped: () => '');

  /// Prefill then decode, as LiteRT-LM's own `GenerateContent` does, in one
  /// hold of the page lock: the runtime's `Session` has no call that does
  /// both, and no other call of the page may run between them.
  @override
  Future<String> generateContent(List<InputData> inputs) async {
    final texts = _texts(inputs);
    return _call('refused the generation', () async {
      await _prefill(texts);
      // Cancelled during the prefill: the decode does not start.
      if (_cancelRequested) return '';
      return _decode();
    }, stopped: () => '');
  }

  @override
  Stream<String> generateContentStream(List<InputData> inputs) => Stream.error(
    UnsupportedError(
      'The web runtime ($liteRtLmWebRuntime) Session has no streaming '
      'decode: use generateContent.',
    ),
  );

  /// The runtime's `Session.cancel()`, which never suspends: it runs outside
  /// the page lock, so it reaches the call in flight, also while [close]
  /// waits for that call to end.
  @override
  void cancelProcess() {
    _cancelRequested = true;
    if (!_deleted) _js.cancel();
  }

  /// The runtime's `Session.clone()`, holding the page lock, as a create the
  /// engine's close waits for: a clone finished after that close began is
  /// deleted and refused.
  @override
  Future<SessionHandle> clone() => _owner.pendingCreate(
    () => _call('could not clone the session', () async {
      final js = await _js.clone().toDart;
      return adopt(
        js,
        _pageLock,
        _owner,
        sampling: _sampling,
        explicitSampler: _explicitSampler,
      );
    }),
  );

  /// Stops the session's call in flight (the runtime's `cancel()`, which
  /// never suspends), then deletes the runtime session once that call has
  /// left the page; a call queued behind it is refused. So an engine's close
  /// does not wait for a whole decode. Marked closed and left out of the
  /// engine's sessions also when the page lock is poisoned: the session is
  /// then left to the page, and the poison is the error.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      try {
        _js.cancel();
      } catch (_) {
        // The delete below still runs; it ends whatever the cancel did not.
      }
      await _pageLock.run(() async {
        try {
          await awaitIfThenable(_js.delete());
        } catch (e) {
          noteWebDeleteFailure('A session', e);
        }
      });
    } finally {
      _deleted = true;
      _owner.sessions.remove(this);
    }
  }
}
