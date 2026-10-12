import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'flutter_edge_ai_runtime.dart';
import 'runtime_errors.dart';

/// The runtime arguments a model is loaded with. flutter_edge_ai reuses the
/// loaded model while these and the active model stay the same, and builds a
/// new one when either changes.
typedef ModelLoadParams = ({
  int maxTokens,
  bool supportImage,
  bool supportAudio,
  bool? enableSpeculativeDecoding,
  gemma.PreferredBackend? preferredBackend,
  gemma.PreferredBackend? preferredVisionBackend,
  gemma.PreferredBackend? preferredAudioBackend,
});

/// The on-device model behind every model name a plugin configures.
///
/// flutter_edge_ai holds one active model, so the configured names are labels
/// for the same native model, and they share this slot's queue: a single
/// generation reaches the model at a time. The slot keeps no model of its
/// own. Every turn asks flutter_edge_ai for the active model, which reuses the
/// loaded one while nothing changed and builds a new one when the arguments
/// or the active model did — a handle cached here would miss both.
class FlutterEdgeAiModelSlot {
  FlutterEdgeAiModelSlot(this.runtime);

  /// Where models are loaded from.
  final FlutterEdgeAiRuntime runtime;

  Future<void> _queue = Future.value();

  /// Takes the next place in the queue. The caller starts its turn with
  /// [ModelTurn.start] and must call [ModelTurn.end] whatever happens.
  ModelTurn enqueue() {
    final turn = ModelTurn._(_queue);
    _queue = turn._done.future;
    return turn;
  }

  /// The active model, loaded with [params]. Call it only during a turn.
  Future<gemma.InferenceModel> load(ModelLoadParams params) =>
      withRuntimeErrors(
        'Could not load the on-device model',
        () => runtime.getActiveModel(
          maxTokens: params.maxTokens,
          supportImage: params.supportImage,
          supportAudio: params.supportAudio,
          enableSpeculativeDecoding: params.enableSpeculativeDecoding,
          preferredBackend: params.preferredBackend,
          preferredVisionBackend: params.preferredVisionBackend,
          preferredAudioBackend: params.preferredAudioBackend,
        ),
      );
}

/// One request's place in a [FlutterEdgeAiModelSlot]'s queue.
class ModelTurn {
  ModelTurn._(this._ahead);

  final Future<void> _ahead;
  final Completer<void> _done = Completer<void>();

  /// Waits until the turn ahead has ended.
  ///
  /// A cancel while waiting throws at once. The place is still held until the
  /// turn ahead ends, so nothing behind it overtakes the generation in
  /// progress.
  Future<void> start(CancellationToken? cancel) async {
    if (cancel == null) return _ahead;
    // onCancel, not whenCancelled: a token reused for a whole chat would
    // keep one listener per call on a future that can never be detached.
    final ready = Completer<void>();
    final detach = cancel.onCancel(() {
      if (!ready.isCompleted) ready.complete();
    });
    unawaited(
      _ahead.then((_) {
        if (!ready.isCompleted) ready.complete();
      }),
    );
    await ready.future;
    detach();
    cancel.throwIfCancelled();
  }

  /// Ends this turn: at once if it has started, otherwise when the turn ahead
  /// ends. Calling it again does nothing.
  void end() {
    unawaited(
      _ahead.whenComplete(() {
        if (!_done.isCompleted) _done.complete();
      }),
    );
  }
}
