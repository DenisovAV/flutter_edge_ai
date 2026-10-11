import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'flutter_edge_ai_runtime.dart';
import 'runtime_errors.dart';

/// The runtime arguments a model is loaded with. A request that asks for
/// different ones loads the model again.
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
/// for the same native model, and they share this slot: one queue, so that a
/// single generation reaches the model at a time, and one cached handle. The
/// handle is dropped when the model closes, which is what loading it again
/// with other arguments does, and when another model becomes active.
class FlutterEdgeAiModelSlot {
  FlutterEdgeAiModelSlot(this.runtime);

  /// Where models are loaded from.
  final FlutterEdgeAiRuntime runtime;

  Future<void> _queue = Future.value();
  gemma.InferenceModel? _model;
  ModelLoadParams? _params;
  String? _modelName;

  /// Takes the next place in the queue. The caller starts its turn with
  /// [ModelTurn.start] and must call [ModelTurn.end] whatever happens.
  ModelTurn enqueue() {
    final turn = ModelTurn._(_queue);
    _queue = turn._done.future;
    return turn;
  }

  /// The active model loaded with [params]: the cached handle while it is
  /// open, was loaded with the same arguments and is still the active model,
  /// a newly loaded one otherwise. Call it only during a turn.
  Future<gemma.InferenceModel> load(ModelLoadParams params) async {
    final activeName = runtime.activeModelName;
    final cached = _model;
    if (cached != null && _params == params && _modelName == activeName) {
      return cached;
    }
    _model = null;
    final model = await withRuntimeErrors(
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
      hasActiveModel: () => runtime.activeModelName != null,
    );
    _model = model;
    _params = params;
    _modelName = activeName;
    model.addCloseListener(() {
      if (identical(_model, model)) _model = null;
    });
    return model;
  }
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
