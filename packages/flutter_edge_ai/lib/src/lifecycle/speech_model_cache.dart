import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

/// What [SpeechModelCache.obtain] does with a model built for one key when a
/// caller asks for another.
enum SpeechModelReuse {
  /// The model serves the request as it is.
  reuse,

  /// Closed, and a model is built for the request.
  rebuild,
}

/// One `getActiveStt` / `getActiveTts` request, resolved by the shell: what
/// it compares, the installed files the model is built from, and how to
/// build it. Resolving it may throw (no active model).
typedef SpeechModelRequest<M, K> = ({
  K key,
  Set<String> files,
  String label,
  Future<M> Function() build,
});

/// A shell's cached speech recognizer or synthesizer, and the rules for
/// reusing it — the speech counterpart of `InferenceModelCache`, shared by
/// the mobile, desktop and web shells for STT and TTS, because the
/// hand-rolled copies of these rules had drifted apart: desktop compared a
/// name the restore path spells differently, web had no guard against two
/// concurrent first builds, and none of them closed the model when its files
/// were uninstalled.
///
/// [obtain] returns the cached model when [_decide] says it serves the
/// request; otherwise it closes it and builds a new one. A caller arriving
/// while a build is in flight shares it when it would reuse its result, and
/// otherwise waits for it and builds its own. No build starts while a
/// previous model is still closing ([ModelCloseGate]) or while
/// [closeForRemoval] runs.
class SpeechModelCache<M extends Object, K extends Object> {
  SpeechModelCache({
    required this._close,
    required this._addCloseListener,
    SpeechModelReuse Function(K cached, K requested)? decide,
    @visibleForTesting ModelCloseGate? closeGate,
  }) : _decide = decide ?? _sameKey,
       _closeGate = closeGate ?? ModelCloseGate();

  final Future<void> Function(M model) _close;
  final void Function(M model, VoidCallback listener) _addCloseListener;

  /// Whether a model built for the first key serves a request for the
  /// second. May throw, to refuse a request without closing the model (TTS:
  /// the same model in another language).
  final SpeechModelReuse Function(K cached, K requested) _decide;
  final ModelCloseGate _closeGate;

  static SpeechModelReuse _sameKey(Object cached, Object requested) =>
      cached == requested ? SpeechModelReuse.reuse : SpeechModelReuse.rebuild;

  /// The cached model and what it was built for. Never set together with
  /// [_building].
  ({M model, K key, Set<String> files})? _cached;

  /// The build in flight and what it is building.
  ({Completer<M> completer, K key, Set<String> files})? _building;

  /// Set while [closeForRemoval] runs: no build starts until it ends.
  Completer<void>? _removal;

  /// The cached model, or null.
  M? get model => _cached?.model;

  /// The model for the request [resolve] describes: the cached one when it
  /// serves it, otherwise the one its `build` returns. [onReuse] runs on a
  /// model handed out without being built for this call (STT retargets its
  /// language there).
  ///
  /// [resolve] runs again after every wait, so a model activated meanwhile
  /// is the one built. Not reentrant: a `build` that calls back into
  /// [obtain] waits for its own build forever.
  Future<M> obtain(
    Future<SpeechModelRequest<M, K>> Function() resolve, {
    void Function(M model)? onReuse,
  }) async {
    while (true) {
      // A file is being removed: resolved again once it is, so the file
      // being removed is not loaded.
      if (_removal case final removal?) {
        await removal.future;
        continue;
      }
      // No model is built while another is still closing.
      if (_closeGate.isClosing) {
        await _closeGate.wait();
        continue;
      }

      final request = await resolve();
      // Resolving awaited: a removal or a close may have started meanwhile.
      if (_removal != null || _closeGate.isClosing) continue;

      if (_cached case final cached?) {
        if (_decide(cached.key, request.key) == SpeechModelReuse.reuse) {
          edgeAiLog('ℹ️  Reusing existing model instance for ${request.label}');
          onReuse?.call(cached.model);
          return cached.model;
        }
        edgeAiLog('⚠️  Rebuilding the model for ${request.label}');
        // Forgotten BEFORE the close is awaited: a caller arriving during the
        // close must not get the closing model, and it waits at the gate.
        _cached = null;
        await _closeGate.closeWith(
          () => _close(cached.model),
          label: request.label,
          tag: cached.files,
        );
        continue;
      }

      if (_building case final building?) {
        if (_decide(building.key, request.key) == SpeechModelReuse.reuse) {
          final model = await building.completer.future;
          onReuse?.call(model);
          return model;
        }
        try {
          await building.completer.future;
        } catch (_) {
          // Its own callers get that error; this caller builds for itself.
        }
        continue;
      }

      return _build(request);
    }
  }

  /// Closes the model built from any of [filenames] — the cached one, or the
  /// one in flight once its build ends — and runs [remove] while no build
  /// starts.
  ///
  /// For an uninstall: left open, the model keeps answering from files that
  /// are gone. A model built from other files stays open. A close of this
  /// model still running at the gate's deadline throws [TimeoutException]
  /// before [remove] runs. Not reentrant: a [remove] that calls [obtain]
  /// waits for itself forever.
  Future<void> closeForRemoval(
    Set<String> filenames,
    Future<void> Function() remove,
  ) async {
    bool builtFrom(Set<String> files) => files.any(filenames.contains);
    while (true) {
      final other = _removal;
      if (other == null) break;
      await other.future;
    }
    final removal = Completer<void>();
    _removal = removal;
    try {
      while (true) {
        final building = _building;
        if (building == null || !builtFrom(building.files)) break;
        try {
          await building.completer.future;
        } catch (_) {
          // Nothing was cached; the build's own callers get its error.
        }
      }
      if (_cached case final cached? when builtFrom(cached.files)) {
        _cached = null;
        await _closeGate.closeWith(
          () => _close(cached.model),
          label: filenames.join(', '),
          tag: cached.files,
        );
      } else if (_closeGate.isClosingWhere(
        (tag) => tag is Set<String> && builtFrom(tag),
      )) {
        await _closeGate.wait();
      }
      await remove();
    } finally {
      _removal = null;
      removal.complete();
    }
  }

  Future<M> _build(SpeechModelRequest<M, K> request) async {
    final completer = Completer<M>();
    _building = (completer: completer, key: request.key, files: request.files);
    final M model;
    try {
      model = await request.build();
    } catch (e, st) {
      return _fail(completer, e, st);
    }
    try {
      // Identity-guarded: a late close of a superseded model must not clear
      // a newer, live one.
      _addCloseListener(model, () {
        if (identical(_cached?.model, model)) _cached = null;
      });
    } catch (e, st) {
      // A model the cache cannot watch is one it cannot hold.
      try {
        await _closeGate.closeWith(
          () => _close(model),
          label: request.label,
          tag: request.files,
        );
      } on TimeoutException {
        // The close keeps running and the gate holds the next caller.
      }
      return _fail(completer, e, st);
    }
    _cached = (model: model, key: request.key, files: request.files);
    _building = null;
    completer.complete(model);
    return model;
  }

  /// Ends [completer]'s build with [error] and frees the slot, so a later
  /// call builds again (#170). Returns the completer's future rather than
  /// rethrowing, so one future carries the error and none is orphaned (#394).
  Future<M> _fail(Completer<M> completer, Object error, StackTrace stackTrace) {
    _building = null;
    completer.completeError(error, stackTrace);
    return completer.future;
  }
}

/// A cache's [SpeechModelCache.closeForRemoval], as the facade calls it.
typedef SpeechRemoval =
    Future<void> Function(
      Set<String> filenames,
      Future<void> Function() remove,
    );

/// Each shell's STT and TTS removals, for `FlutterEdgeAi.uninstallStt` and
/// `uninstallTts`, which reach a shell only as a `FlutterEdgeAiPlugin`. A side
/// table rather than a member, so no shell's public API grows one.
final _sttRemovals = Expando<SpeechRemoval>('SttModelCache');
final _ttsRemovals = Expando<SpeechRemoval>('TtsModelCache');

/// Records the removals of [shell]'s STT and TTS caches. A shell without TTS
/// (web) passes none.
void attachSpeechModelCaches(
  Object shell, {
  required SpeechRemoval stt,
  SpeechRemoval? tts,
}) {
  _sttRemovals[shell] = stt;
  if (tts != null) _ttsRemovals[shell] = tts;
}

/// The STT removal [attachSpeechModelCaches] recorded for [shell], or null: a
/// plugin that is not one of core's shells caches no recognizer here.
SpeechRemoval? sttRemovalOf(Object shell) => _sttRemovals[shell];

/// The TTS removal [attachSpeechModelCaches] recorded for [shell], or null.
SpeechRemoval? ttsRemovalOf(Object shell) => _ttsRemovals[shell];

/// What an STT recognizer is cached for: the files it opens. Compared
/// instead of the spec name, which the restore path spells differently from
/// an install, so the desktop shell rebuilt on every call.
typedef SttCacheKey = ({String modelPath, String tokenizerPath});

/// What a TTS synthesizer is cached for: the active model and the language,
/// normalized by [normalizeTtsLanguage].
typedef TtsCacheKey = ({String name, String language});

/// Normalizes a `getActiveTts` `language` for the reuse rule: `null` is
/// `'english'` (as `LiteRtTtsBackend.createModel` defaults it) and case is
/// ignored, so `null`, `'english'` and `'English'` build the same synthesizer
/// and compare equal.
String normalizeTtsLanguage(String? language) =>
    (language ?? 'english').toLowerCase();

/// The TTS reuse rule: another model is rebuilt; the same model in another
/// language is refused, because reusing it would speak the wrong language
/// with no error and replacing it would close a synthesizer the app still
/// holds — the app closes it first.
SpeechModelReuse decideTtsReuse(TtsCacheKey cached, TtsCacheKey requested) {
  if (cached.name != requested.name) return SpeechModelReuse.rebuild;
  if (cached.language != requested.language) {
    throw StateError(
      'Active TTS synthesizer was created for language '
      "'${cached.language}'; call close() before requesting "
      "'${requested.language}'.",
    );
  }
  return SpeechModelReuse.reuse;
}
