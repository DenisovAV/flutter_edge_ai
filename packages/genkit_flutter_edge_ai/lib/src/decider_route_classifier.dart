// The Decider API is experimental (flutter_edge_ai pins it below 2.6.0 for
// this file); its use draws the experimental_member_use warning.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:genkit_hybrid/genkit_hybrid.dart';

/// A genkit_hybrid [RouteClassifier] over a flutter_edge_ai [Decider]: an
/// EmbeddingGemma 2 decider (`EmbeddingModel.createDecider` /
/// `loadDecider`) or a language-model one (`InferenceModel.createDecider`).
/// Its options are the labels; map them to targets in the policy's `labels`.
///
/// [decider] is asked on every request, because a decider loads for seconds
/// and is replaced on refit. While it loads, return the pending Future: the
/// request waits for it, with no limit unless the call has a Genkit cancel
/// token, which ends the wait. Return null when there is none (not
/// configured): the classifier is then unavailable, and the policy's
/// `onUnavailable` decides. A Future that fails fails the call with its
/// error, never routed around; to retry a failed load, drop the cached
/// Future when it fails. The decider is borrowed — this classifier never
/// closes it — so cache the Future, and never hand out a decider you
/// closed.
///
/// [text] picks what is classified; by default the last user message's
/// text. No text is an abstain (`noText`). Everything else the decider
/// throws fails the call, never an abstain: an over-long request included,
/// so put `RouteRule.inputSize` before the classifier.
///
/// `warmUp` waits for the provider's decider, so a router's warm-up loads
/// it before the first request. To have the classifier make and keep the
/// decider itself, use [DeciderRouteClassifier.load].
///
/// Experimental, like the Decider API it adapts.
RouteClassifier deciderRouteClassifier(
  FutureOr<Decider?> Function() decider, {
  String name = 'flutter-edge-ai/decider',
  String? Function(RouteRequest request)? text,
}) => _DeciderRouteClassifier(decider, name, text);

final class _DeciderRouteClassifier extends RouteClassifier {
  _DeciderRouteClassifier(this._decider, this.name, this._text);

  final FutureOr<Decider?> Function() _decider;
  final String? Function(RouteRequest request)? _text;

  @override
  final String name;

  @override
  Future<void> warmUp({CancellationToken? cancel}) => _current(cancel);

  @override
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  }) async {
    final text = _text == null ? request.lastUserText : _text(request);
    if (text == null || text.trim().isEmpty) {
      return const RouteVerdict.abstain('noText');
    }
    final first = await _current(cancel);
    try {
      return await _choose(first, text, cancel);
    } on _DeciderClosed catch (closed) {
      // A refit closed it: the provider may already hand out the new one.
      final second = await _current(cancel);
      if (identical(second, first)) {
        throw RouteClassifierUnavailableException(closed.message);
      }
      try {
        return await _choose(second, text, cancel);
      } on _DeciderClosed catch (again) {
        throw RouteClassifierUnavailableException(again.message);
      }
    }
  }

  /// The provider's decider, waiting for a pending one unless [cancel] ends
  /// the wait.
  Future<Decider> _current(CancellationToken? cancel) async {
    cancel?.throwIfCancelled();
    final pending = Future.value(_decider());
    final Decider? decider;
    if (cancel == null) {
      decider = await pending;
    } else {
      // onCancel, not whenCancelled: an app may reuse one token for many
      // calls, and a listener on it must go when the wait ends.
      final done = Completer<Decider?>();
      final detach = cancel.onCancel(() {
        if (!done.isCompleted) done.complete(null);
      });
      pending.then(
        (d) {
          if (!done.isCompleted) done.complete(d);
        },
        onError: (Object e, StackTrace s) {
          if (!done.isCompleted) done.completeError(e, s);
        },
      );
      try {
        decider = await done.future;
      } finally {
        detach();
      }
      cancel.throwIfCancelled();
    }
    if (decider == null) {
      throw const RouteClassifierUnavailableException(
        'No decider: it is not configured.',
      );
    }
    if (!identical(
      decider.capabilities.questionType,
      DeciderQuestionType.choice,
    )) {
      // The app's configuration, not the user's request.
      throw StateError(
        'A ${decider.capabilities.questionType.name} decider cannot route: '
        'it never chooses one option.',
      );
    }
    return decider;
  }

  Future<RouteVerdict> _choose(
    Decider decider,
    String text,
    CancellationToken? cancel,
  ) async {
    if (decider.isClosed) throw const _DeciderClosed();
    // A fresh token per call: the inference decider listens on it for every
    // choose, so a shared one would collect listeners.
    final token = CancelToken();
    final detach = cancel?.onCancel(() => token.cancel('Genkit cancelled'));
    Future<DeciderAnswer> choose() => decider.choose(
      DeciderInput(EmbeddingInput.text(text)),
      cancelToken: token,
    );
    try {
      // No await between the isClosed check and choose, so a close cannot
      // slip in between.
      DeciderAnswer answer;
      try {
        answer = await choose();
      } on EmbedderClosedException {
        // A decider on core's active embedder moves to its replacement, and
        // one closed while it moved is gone at the next choose.
        if (decider.isClosed) rethrow;
        answer = await choose();
      }
      return _verdict(answer);
    } on DeciderCancelledException {
      // Without a Genkit cancel it means the decider closed mid-choose.
      if (cancel?.isCancelled ?? false) rethrow;
      throw const _DeciderClosed();
    } on EmbedderClosedException {
      // Its embedder was closed under it: as good as a closed decider.
      throw decider.isClosed
          ? const _DeciderClosed()
          : const _DeciderClosed('The decider\'s embedder was closed.');
    } on StateError {
      if (decider.isClosed) throw const _DeciderClosed();
      rethrow;
    } finally {
      detach?.call();
    }
  }

  static RouteVerdict _verdict(DeciderAnswer answer) {
    final p = answer.provenance;
    final top = answer.ranked.firstOrNull;
    final details = <String, Object?>{
      'method': p.method.name,
      'calibration': p.calibration,
      'spaceId': ?p.spaceId,
      'threshold': ?_finite(p.threshold),
      'signal': ?_finite(p.abstainSignal),
      'signalKind': ?p.abstainSignalKind?.name,
      'scoreKind': answer.scoreKind.name,
      'topScore': ?_finite(top?.score),
      'topProbability': ?_finite(top?.probability),
      'confidence': ?_finite(answer.confidence),
      'encodeMs': p.encodeTime.inMicroseconds / 1000,
      'scoreMs': p.scoreTime.inMicroseconds / 1000,
    };
    if (answer.abstainReason case final reason?) {
      return RouteVerdict.abstain(reason.name, details: details);
    }
    final choice = answer.choice;
    if (choice == null) {
      throw StateError('The decider neither chose nor abstained.');
    }
    // abstainSignal is the value the threshold is compared with; higher is
    // more confident for every decider kind, unlike the ranked scores.
    return RouteVerdict.label(
      choice,
      score: _finite(p.abstainSignal),
      margin: _finite(answer.margin),
      details: details,
    );
  }

  /// [v] when finite: JSON (the route info, the trace) has no infinity, and
  /// a one-option decider's margin is one.
  static double? _finite(double? v) => v != null && v.isFinite ? v : null;
}

final class _DeciderClosed implements Exception {
  const _DeciderClosed([this.message = 'The decider was closed.']);

  /// Why the classifier is unavailable, if no other decider takes over.
  final String message;
}

/// A genkit_hybrid [RouteClassifier] that owns its decider: [load] makes it,
/// starting when the classifier is created, and the classifier keeps it for
/// every request, as `deciderRouteClassifier` does over a provider.
///
/// A load that fails fails the requests waiting for it, never routed around,
/// and the next request loads again. [reload] makes a new decider (a refit)
/// and closes the old one once the new one is ready; the old one answers
/// until then, and a failed reload keeps it. [close] closes the decider;
/// the classifier is unavailable afterwards.
///
/// Experimental, like the Decider API it adapts.
final class DeciderRouteClassifier extends RouteClassifier {
  /// Starts [load] now. [name] and [text] are `deciderRouteClassifier`'s.
  DeciderRouteClassifier.load(
    Future<Decider> Function() load, {
    String name = 'flutter-edge-ai/decider',
    String? Function(RouteRequest request)? text,
  }) : _load = load {
    _inner = _DeciderRouteClassifier(_provide, name, text);
    _start();
  }

  final Future<Decider> Function() _load;
  late final _DeciderRouteClassifier _inner;

  /// The decider in use, or the load that is making it; null after a failed
  /// load, until the next request starts one.
  Future<Decider>? _decider;

  /// Counts reloads: only the latest one may install its decider.
  int _generation = 0;
  bool _closed = false;

  @override
  String get name => _inner.name;

  @override
  Future<void> warmUp({CancellationToken? cancel}) =>
      _inner.warmUp(cancel: cancel);

  @override
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  }) => _inner.classify(request, cancel: cancel);

  /// Makes a new decider and, once it is ready, uses it and closes the old
  /// one. Throws what the load threw, and the old decider stays in use.
  Future<void> reload() async {
    if (_closed) throw StateError('The classifier was closed.');
    final generation = ++_generation;
    final decider = await Future.sync(_load);
    if (_closed || generation != _generation) {
      // Closed meanwhile, or a later reload replaced this one.
      await decider.close();
      return;
    }
    final old = _decider;
    _decider = Future.value(decider);
    if (old != null) await _closeWhenLoaded(old, keep: decider);
  }

  /// Closes the decider. Requests are unavailable afterwards.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final current = _decider;
    _decider = null;
    if (current != null) await _closeWhenLoaded(current);
  }

  Future<Decider?> _provide() {
    if (_closed) {
      return Future.error(
        const RouteClassifierUnavailableException('The classifier was closed.'),
      );
    }
    return _decider ?? _start();
  }

  Future<Decider> _start() {
    final load = Future.sync(_load);
    _decider = load;
    // A failed load is dropped, so the next request loads again; the error
    // reaches the requests waiting for it through the Future itself.
    load.then(
      (_) {},
      onError: (Object _) {
        if (identical(_decider, load)) _decider = null;
      },
    );
    return load;
  }

  /// Closes the decider [pending] makes, unless it is [keep]. One that failed
  /// to load has nothing to close: its error went to its requests.
  static Future<void> _closeWhenLoaded(
    Future<Decider> pending, {
    Decider? keep,
  }) => pending.then(
    (d) => identical(d, keep) ? null : d.close(),
    onError: (Object _) {},
  );
}
