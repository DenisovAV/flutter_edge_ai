// Embedding a decider's inputs: its options' descriptions and examples, and
// the labelled rows of a `fromLabelled` calibration. One request per input,
// at most two outstanding (as `embedAll` keeps them), so that a failure names
// the input it belongs to and every finished input can be counted.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../embedding/embedding_exceptions.dart';
import '../embedding/embedding_input.dart';
import '../embedding/embedding_model.dart';
import '../embedding/task_type.dart';
import '../model_management/cancel_token.dart' show CancelToken;

/// How many of the decider's requests may be outstanding at once: enough to
/// keep a worker busy, few enough that a cancel stops almost everything.
const _window = 2;

/// [inputs] embedded with [taskType] as unit rows (inputs × [dimension],
/// row-major).
///
/// [name] says which input index `i` is (`Option "a", example 2`); an
/// input-specific failure is rebuilt as the same exception type with that in
/// front of its message, and a vector that is not finite, not [dimension]
/// long or zero is a [StateError] naming it. Each input's modalities are
/// checked against `embedder.modalities` before anything is sent.
///
/// [cancelToken] fails the call with `EmbeddingCancelledException` at once;
/// requests already outstanding finish and are dropped. [onEmbedded] runs
/// after each input's vector is in.
Future<Float64List> embedDeciderRows(
  EmbeddingModel embedder,
  List<EmbeddingInput> inputs, {
  required TaskType taskType,
  required int dimension,
  required String Function(int index) name,
  CancelToken? cancelToken,
  void Function()? onEmbedded,
}) {
  final loaded = embedder.modalities;
  for (var i = 0; i < inputs.length; i++) {
    for (final modality in inputs[i].modalities) {
      if (!loaded.contains(modality)) {
        return Future.error(
          EmbeddingModalityNotLoadedException(
            '${name(i)}: the input carries ${modality.name}, which this model '
            'was not loaded for (it embeds '
            '${loaded.map((m) => m.name).join(' and ')}).',
            modality: modality,
            loaded: loaded,
          ),
        );
      }
    }
  }
  if (cancelToken?.isCancelled ?? false) {
    return Future.error(const EmbeddingCancelledException(_cancelled));
  }
  final out = Float64List(inputs.length * dimension);
  if (inputs.isEmpty) return Future.value(out);

  final result = Completer<Float64List>();
  final link = cancelToken == null ? null : _CancelLink();
  var next = 0;
  var outstanding = 0;
  var finished = 0;

  void fail(Object error, StackTrace stack) {
    if (result.isCompleted) return;
    link?.clear();
    result.completeError(error, stack);
  }

  void sendMore() {
    while (!result.isCompleted &&
        outstanding < _window &&
        next < inputs.length) {
      if (cancelToken?.isCancelled ?? false) {
        fail(const EmbeddingCancelledException(_cancelled), StackTrace.current);
        return;
      }
      final index = next++;
      outstanding++;
      // Future.sync: an embedder whose embed throws synchronously still
      // fails this call instead of escaping it.
      Future.sync(() => embedder.embed(inputs[index], taskType: taskType)).then(
        (vector) {
          outstanding--;
          if (result.isCompleted) return;
          // Nothing here may throw past the call: an error escaping this
          // callback would be unobserved and leave the call pending.
          try {
            unitRowInto(vector, dimension, out, index * dimension, name(index));
            finished++;
            onEmbedded?.call();
            if (finished == inputs.length) {
              link?.clear();
              result.complete(out);
            } else {
              sendMore();
            }
          } catch (e, st) {
            fail(e, st);
          }
        },
        onError: (Object error, StackTrace stack) {
          outstanding--;
          fail(namedFailure(error, name(index)), stack);
        },
      );
    }
  }

  if (cancelToken != null && link != null) {
    link.onCancel = () =>
        fail(const EmbeddingCancelledException(_cancelled), StackTrace.current);
    _listenForCancel(cancelToken, link);
  }
  sendMore();
  return result.future;
}

const _cancelled = 'createDecider was cancelled.';

/// Writes [vector], normalised, into [out] at [offset]; refuses a wrong
/// length, a non-finite value or a zero vector — never a decision computed
/// from NaN. [what] names the vector in the error.
void unitRowInto(
  List<double> vector,
  int d,
  Float64List out,
  int offset,
  String what,
) {
  if (vector.length != d) {
    throw StateError(
      'The embedder returned ${vector.length} values for $what; its '
      'dimension is $d.',
    );
  }
  var norm = 0.0;
  for (final v in vector) {
    if (!v.isFinite) {
      throw StateError(
        'The embedder returned a non-finite value for $what; a decision is '
        'never computed from it.',
      );
    }
    norm += v * v;
  }
  if (norm == 0) {
    throw StateError('The embedder returned a zero vector for $what.');
  }
  norm = math.sqrt(norm);
  for (var j = 0; j < d; j++) {
    out[offset + j] = vector[j] / norm;
  }
}

/// [error] with "[what]: " in front of its message when it is a failure of
/// that one input; the same type, with the same fields. A closed embedder, a
/// cancel and anything else that is not about the input pass unchanged.
Object namedFailure(Object error, String what) {
  String message(EmbeddingException e) => '$what: ${e.message}';
  return switch (error) {
    EmbeddingModalityNotLoadedException(:final modality, :final loaded) =>
      EmbeddingModalityNotLoadedException(
        message(error),
        modality: modality,
        loaded: loaded,
      ),
    UnsupportedEmbeddingCombinationException(:final requested) =>
      UnsupportedEmbeddingCombinationException(
        message(error),
        requested: requested,
      ),
    EmbeddingFormatNotSupportedException(
      :final modality,
      :final detected,
      :final accepted,
    ) =>
      EmbeddingFormatNotSupportedException(
        message(error),
        modality: modality,
        detected: detected,
        accepted: accepted,
      ),
    EmbeddingInputTooLongException(
      :final maxInputTokens,
      :final actualTokens,
    ) =>
      EmbeddingInputTooLongException(
        message(error),
        maxInputTokens: maxInputTokens,
        actualTokens: actualTokens,
      ),
    EmbeddingEngineException(:final engine, :final nativeCode, :final cause) =>
      EmbeddingEngineException(
        message(error),
        engine: engine,
        nativeCode: nativeCode,
        cause: cause,
      ),
    StateError(:final message) => StateError('$what: $message'),
    _ => error,
  };
}

/// What a `CancelToken`'s listener holds for one call: the call's cancel
/// action until the call settles, nothing after — a token kept for the life
/// of an app retains nothing of the calls it was passed to.
final class _CancelLink {
  void Function()? onCancel;

  void fire() => onCancel?.call();

  void clear() => onCancel = null;
}

/// Top-level on purpose: a closure created inside [embedDeciderRows] would
/// share its context — which holds the vectors — and the token would keep all
/// of it alive.
void _listenForCancel(CancelToken token, _CancelLink link) {
  unawaited(token.whenCancelled.then((_) => link.fire()));
}
