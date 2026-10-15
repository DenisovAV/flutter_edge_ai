// Web: no isolate to spare, so the fit runs on the page's thread — in slices.
// Every row, fold and history entry asks a pacer that, after a few
// milliseconds of work, yields to the event loop (a MessageChannel task, the
// inline embedding host's own yield), so frames, input and timers run while a
// fit takes seconds; each yield checks the cancel token.
//
// dart:js_interop only (through the yield), so the web graph stays free of
// dart:io/ffi/isolate. The VM picks the zero-timer yield, so this runner can
// be tested there too.

import '../embedding/embedding_exceptions.dart'
    show EmbeddingCancelledException;
import '../embedding/event_loop_yield.dart'
    if (dart.library.js_interop) '../embedding/event_loop_yield_web.dart';
import '../model_management/cancel_token.dart' show CancelToken;
import 'decider_fit.dart';
import 'fit_pacer.dart';

const _cancelled = 'createDecider was cancelled.';

/// How long the fit works between two turns of the event loop.
const fitSlice = Duration(milliseconds: 4);

/// Runs [fitDecider] on this thread, yielding to the event loop every
/// [fitSlice] of work. [cancelToken] fails the call with
/// `EmbeddingCancelledException` at the next yield.
Future<DeciderFit> runDeciderFit(
  DeciderFitRequest request, {
  CancelToken? cancelToken,
}) {
  if (cancelToken?.isCancelled ?? false) {
    return Future.error(const EmbeddingCancelledException(_cancelled));
  }
  return fitDecider(request, pacer: CooperativeFitPacer(cancelToken));
}

/// Pauses once [fitSlice] of work has passed since the last turn.
final class CooperativeFitPacer implements FitPacer {
  CooperativeFitPacer(this._cancelToken, {Duration slice = fitSlice})
    : _sliceMicros = slice.inMicroseconds;

  final CancelToken? _cancelToken;
  final int _sliceMicros;
  final Stopwatch _since = Stopwatch()..start();

  /// How many times the fit yielded. For tests.
  int turns = 0;

  @override
  Future<void>? pause() =>
      _since.elapsedMicroseconds < _sliceMicros ? null : _turn();

  Future<void> _turn() async {
    turns++;
    await yieldToEventLoop();
    if (_cancelToken?.isCancelled ?? false) {
      throw const EmbeddingCancelledException(_cancelled);
    }
    _since.reset();
  }
}
