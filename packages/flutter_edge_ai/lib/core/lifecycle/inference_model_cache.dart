import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/core/registry/runtime_config.dart'
    show ActiveModelParams;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show InferenceModel;

/// Which model a cached build is for: the active spec, compared by value —
/// a LoRA added to the same file, or the file re-installed from another
/// source, keeps the name and changes the weights — and the modelType and
/// fileType it was built as. Mobile and desktop take those two from the spec;
/// web takes them from the caller, as it always has.
typedef InferenceModelIdentity = ({
  InferenceModelSpec spec,
  ModelType modelType,
  ModelFileType fileType,
});

/// One `getActiveModel` request, resolved by the shell: which model, with
/// which knobs, how to build it, and the name logs and a close-wait timeout
/// use. Resolving it may throw (`NoActiveModelError`).
typedef InferenceModelRequest = ({
  InferenceModelIdentity identity,
  ActiveModelParams params,
  Future<InferenceModel> Function() build,
  String label,
});

/// The shells' cached inference model, and the rules for reusing it — shared
/// by the mobile, desktop and web shells, as `EmbedderCache` is for the
/// embedder, because hand-rolled copies of these rules drift apart.
///
/// [obtain] returns the cached model while it is open, was built for the same
/// [InferenceModelIdentity] and the same [ActiveModelParams]; otherwise it
/// closes it and builds a new one. A caller arriving while a build is in
/// flight shares it when it asks for the same thing, and otherwise waits for
/// it and builds its own. No build starts while a previous model is still
/// closing ([ModelCloseGate]).
class InferenceModelCache {
  InferenceModelCache([@visibleForTesting ModelCloseGate? closeGate])
    : _closeGate = closeGate ?? ModelCloseGate();

  final ModelCloseGate _closeGate;

  /// The build of [_model] — pending while it is in flight, completed once it
  /// is the cached model. Kept on success on purpose: it IS the cache.
  Completer<InferenceModel>? _completer;

  InferenceModel? _model;

  /// What [_model] was built for, and with which knobs.
  InferenceModelIdentity? _identity;
  ActiveModelParams? _params;

  /// What the IN-FLIGHT build is building, while [_completer] is pending.
  /// Separate from [_identity]/[_params], which describe the model that
  /// already exists: "cached model" vs "model being built" is exactly the
  /// distinction the race in [obtain] turns on. Set where [_completer] is
  /// created, cleared everywhere it is cleared.
  ({InferenceModelIdentity identity, ActiveModelParams params})? _inFlight;

  /// The cached model, or null.
  InferenceModel? get model => _model;

  /// The model for the request [resolve] describes: the cached one when it
  /// fits, otherwise the one its `build` returns.
  ///
  /// [resolve] runs again whenever the cache has waited for a build in flight
  /// and starts over, so a model installed meanwhile is the one built.
  Future<InferenceModel> obtain(
    InferenceModelRequest Function() resolve,
  ) async {
    final (:identity, :params, :build, :label) = resolve();

    // No model is built while another is still closing: two native models
    // must not be resident at once.
    if (_closeGate.isClosing) await _closeGate.wait();

    // A cached model whose close has started is going away, and its close
    // listener fires only once the teardown ends. Forget it, wait for that
    // teardown, then build anew; the listener is identity-guarded and will
    // not touch the new model.
    if (_model case final cached? when cached.isClosed) {
      _reset();
      await _closeGate.closeAndWait(cached, label: label);
    }

    if (_completer != null && _model != null && _identity != null) {
      final modelChange = _describeChange(_identity!, identity);
      // A MISSING baseline means rebuild, not reuse: "no record of what this
      // model was built with" must not read as "built with exactly this".
      // Guessing "rebuild" reloads weights that were right; guessing "reuse"
      // hands back a model configured for something else and says nothing.
      final baseline = _params;
      final changedParam = baseline == null
          ? 'unknown — no recorded config for the cached model'
          : baseline.firstDifference(params);

      if (modelChange == null && changedParam == null) {
        edgeAiLog('ℹ️  Reusing existing model instance for $label');
        return _completer!.future;
      }
      edgeAiLog(
        modelChange != null
            ? '⚠️  Active model changed ($modelChange) — rebuilding the model'
            : '⚠️  Runtime config changed ($changedParam) for $label — '
                  'rebuilding the model',
      );
      // State cleared BEFORE the close is awaited: a caller arriving during
      // the close must not pass the reuse check and get the closing model,
      // and two callers with different params must not both install builds.
      // The close goes through the gate, so a caller arriving meanwhile waits
      // for it; a failed close is logged, not passed on.
      final closing = _model;
      _reset();
      if (closing != null) {
        await _closeGate.closeAndWait(closing, label: label);
      }
    }

    // A build already in flight is shared only with a caller asking for the
    // same model and knobs. Anyone else waits for it and builds their own:
    // handing them the in-flight build gave a GPU request the CPU model.
    if (_completer case final completer?) {
      final pending = _inFlight;
      final modelChange = pending == null
          ? null
          : _describeChange(pending.identity, identity);
      final changedParam = pending?.params.firstDifference(params);
      if (pending != null && modelChange == null && changedParam == null) {
        return completer.future;
      }
      edgeAiLog(
        '⏳ A model build is already in flight with a different request '
        '(${modelChange ?? 'config $changedParam'}) — waiting for it, then '
        'rebuilding',
      );
      var inFlightFailed = false;
      try {
        await completer.future;
      } catch (_) {
        // Its own caller gets that error; this caller builds fresh.
        inFlightFailed = true;
        edgeAiLog('In-flight build failed; building fresh for this request');
      }
      if (inFlightFailed && identical(_completer, completer)) {
        // Do not recurse into the same dead completer forever.
        _completer = null;
        _inFlight = null;
      }
      // Re-enter rather than tear down mid-build: the first caller gets the
      // model it asked for; the reuse check then sees other params and does
      // the ordinary close-and-rebuild.
      return obtain(resolve);
    }

    final completer = _completer = Completer<InferenceModel>();
    _inFlight = (identity: identity, params: params);
    try {
      final model = await build();
      _model = model;
      // Identity-guarded: a late close of a superseded model must not clear a
      // newer, live one, whose next caller would then reload its weights.
      model.addCloseListener(() {
        if (identical(_model, model)) _reset();
      });
      _identity = identity;
      _params = params;
      _inFlight = null;
      completer.complete(model);
      return model;
    } catch (e, st) {
      // Reset so a later call can build; the completer's future, not a
      // rethrow, so one future is in flight and none is orphaned (#394).
      _reset();
      completer.completeError(e, st);
      return completer.future;
    }
  }

  void _reset() {
    _completer = null;
    _inFlight = null;
    _model = null;
    _identity = null;
    _params = null;
  }

  /// How [to] differs from [from] as a model to build, or null if it does
  /// not.
  static String? _describeChange(
    InferenceModelIdentity from,
    InferenceModelIdentity to,
  ) {
    if (from.spec.name != to.spec.name) {
      return '${from.spec.name} → ${to.spec.name}';
    }
    if (from.spec != to.spec) {
      return '${to.spec.name} re-installed with another source or LoRA';
    }
    if (from.modelType != to.modelType) {
      return 'modelType ${from.modelType.name} → ${to.modelType.name}';
    }
    if (from.fileType != to.fileType) {
      return 'fileType ${from.fileType.name} → ${to.fileType.name}';
    }
    return null;
  }
}
