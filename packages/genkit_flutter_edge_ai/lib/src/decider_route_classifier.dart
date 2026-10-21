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
/// request waits for it (a Genkit cancel ends the wait). Return null when
/// there is none to wait for (not configured, its load failed): the
/// classifier is then unavailable, and the policy's `onUnavailable` decides.
/// The decider is borrowed — this classifier never closes it — so cache the
/// Future, and never hand out a decider you closed.
///
/// [text] picks what is classified; by default the last user message's
/// text. No text is an abstain (`noText`). Everything else the decider
/// throws fails the call, never an abstain: an over-long request included,
/// so put `RouteRule.inputSize` before the classifier.
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
    } on _DeciderClosed {
      // A refit closed it: the provider may already hand out the new one.
      final second = await _current(cancel);
      if (identical(second, first)) {
        throw const RouteClassifierUnavailableException(
          'The decider was closed.',
        );
      }
      try {
        return await _choose(second, text, cancel);
      } on _DeciderClosed {
        throw const RouteClassifierUnavailableException(
          'The decider was closed.',
        );
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
      final first = await Future.any<Object?>([
        pending,
        cancel.whenCancelled.then((_) => _cancelled),
      ]);
      cancel.throwIfCancelled();
      decider = first as Decider?;
    }
    if (decider == null) {
      throw const RouteClassifierUnavailableException(
        'No decider: it is not configured, or its load failed.',
      );
    }
    if (!identical(
      decider.capabilities.questionType,
      DeciderQuestionType.choice,
    )) {
      throw ArgumentError(
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
    try {
      // No await between the isClosed check and choose, so a close cannot
      // slip in between.
      final answer = await decider.choose(
        DeciderInput(EmbeddingInput.text(text)),
        cancelToken: token,
      );
      return _verdict(answer);
    } on DeciderCancelledException {
      // Without a Genkit cancel it means the decider closed mid-choose.
      if (cancel?.isCancelled ?? false) rethrow;
      throw const _DeciderClosed();
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

const Object _cancelled = Object();

final class _DeciderClosed implements Exception {
  const _DeciderClosed();
}
