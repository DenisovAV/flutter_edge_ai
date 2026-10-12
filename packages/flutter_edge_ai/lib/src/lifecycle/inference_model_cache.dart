import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart'
    show ActiveModelParams, RuntimeConfig;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/interface.dart' show InferenceModel;

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
/// which knobs, and how to build it. Resolving it may throw
/// (`NoActiveModelError`).
typedef InferenceModelRequest = ({
  InferenceModelIdentity identity,
  ActiveModelParams params,
  Future<InferenceModel> Function() build,
});

/// The engine config for a model built with [params] from [modelPath]: every
/// knob the cache compares, listed once, so what the cache compares is what
/// the engine gets. Desktop once compared `loraRanks` and did not forward it.
RuntimeConfig runtimeConfigFor(
  ActiveModelParams params, {
  required String modelPath,
}) => RuntimeConfig(
  maxTokens: params.maxTokens,
  modelPath: modelPath,
  preferredBackend: params.preferredBackend,
  preferredVisionBackend: params.preferredVisionBackend,
  preferredAudioBackend: params.preferredAudioBackend,
  supportImage: params.supportImage,
  supportAudio: params.supportAudio,
  maxNumImages: params.maxNumImages,
  enableSpeculativeDecoding: params.enableSpeculativeDecoding,
  activationDataType: params.activationDataType,
  maxConcurrentSessions: params.maxConcurrentSessions,
  loraRanks: params.loraRanks,
);

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

  /// The cached model and what it was built for. One field, so "a model with
  /// no record of what it was built for" is not a state this class can be in.
  ({
    InferenceModel model,
    InferenceModelIdentity identity,
    ActiveModelParams params,
  })?
  _cached;

  /// The build in flight and what it is building. Never set together with
  /// [_cached]: a build starts only once nothing is cached, so the cache holds
  /// one model.
  ({
    Completer<InferenceModel> completer,
    InferenceModelIdentity identity,
    ActiveModelParams params,
  })?
  _building;

  /// The cached model, or null.
  InferenceModel? get model => _cached?.model;

  /// The model for the request [resolve] describes: the cached one when it
  /// fits, otherwise the one its `build` returns.
  ///
  /// [resolve] runs again after every wait — for a close, or for a build in
  /// flight — so a model activated meanwhile is the one built.
  ///
  /// A caller that gets a model has no claim on it: a later caller asking
  /// for other knobs closes it and builds its own, because the cache holds
  /// one model. Not reentrant: a `build` that calls back into [obtain] waits
  /// for its own build forever.
  Future<InferenceModel> obtain(
    InferenceModelRequest Function() resolve,
  ) async {
    while (true) {
      final (:identity, :params, :build) = resolve();

      // No model is built while another is still closing: two native models
      // must not be resident at once.
      if (_closeGate.isClosing) {
        await _closeGate.wait();
        continue;
      }

      if (_cached case final cached?) {
        // A model whose close has started is going away, even before its
        // close listener fires — that happens only once the teardown ends.
        final reason = cached.model.isClosed
            ? 'closed by its owner'
            : _whyRebuild(cached.identity, cached.params, identity, params);
        if (reason == null) {
          edgeAiLog(
            'ℹ️  Reusing existing model instance for ${_name(identity)}',
          );
          return cached.model;
        }
        edgeAiLog('⚠️  Rebuilding the model: $reason');
        // Forgotten BEFORE the close is awaited: a caller arriving during the
        // close must not get the closing model, and it waits at the gate.
        // The close listener is identity-guarded and will not touch whatever
        // is cached next.
        _cached = null;
        await _closeGate.closeAndWait(
          cached.model,
          label: _name(cached.identity),
        );
        continue;
      }

      // A build already in flight is shared only with a caller asking for the
      // same model and knobs. Anyone else waits for it and builds their own:
      // handing them the in-flight build gave a GPU request the CPU model.
      if (_building case final building?) {
        final reason = _whyRebuild(
          building.identity,
          building.params,
          identity,
          params,
        );
        if (reason == null) return building.completer.future;
        edgeAiLog('⏳ Waiting for the build in flight ($reason)');
        try {
          await building.completer.future;
        } catch (e) {
          // Its own callers get that error; this caller builds for itself.
          edgeAiLog(
            'The build in flight failed ($e); building for this request',
          );
        }
        continue;
      }

      return _build(identity, params, build);
    }
  }

  Future<InferenceModel> _build(
    InferenceModelIdentity identity,
    ActiveModelParams params,
    Future<InferenceModel> Function() build,
  ) async {
    final completer = Completer<InferenceModel>();
    _building = (completer: completer, identity: identity, params: params);
    final InferenceModel model;
    try {
      model = await build();
    } catch (e, st) {
      return _fail(completer, e, st);
    }
    try {
      // Identity-guarded: a late close of a superseded model must not clear
      // a newer, live one, whose next caller would then reload its weights.
      model.addCloseListener(() {
        if (identical(_cached?.model, model)) _cached = null;
      });
    } catch (e, st) {
      // A model the cache cannot watch is one it cannot hold: it would never
      // learn the model went away. Close it rather than leave its weights
      // resident with no owner, then fail the request with the reason.
      try {
        await _closeGate.closeAndWait(model, label: _name(identity));
      } on TimeoutException {
        // The close keeps running and the gate holds the next caller until
        // it ends; this caller's error is the listener's, not the wait's.
      }
      return _fail(completer, e, st);
    }
    _cached = (model: model, identity: identity, params: params);
    _building = null;
    completer.complete(model);
    return model;
  }

  /// Ends [completer]'s build with [error] and frees the slot, so a later
  /// call builds again (#170). Returns the completer's future rather than
  /// rethrowing, so one future carries the error and none is orphaned (#394).
  Future<InferenceModel> _fail(
    Completer<InferenceModel> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    _building = null;
    completer.completeError(error, stackTrace);
    return completer.future;
  }

  static String _name(InferenceModelIdentity identity) => identity.spec.name;

  /// Why a model built for [fromIdentity] and [fromParams] does not serve
  /// [identity] and [params], or null when it does.
  static String? _whyRebuild(
    InferenceModelIdentity fromIdentity,
    ActiveModelParams fromParams,
    InferenceModelIdentity identity,
    ActiveModelParams params,
  ) {
    final from = fromIdentity.spec;
    final to = identity.spec;
    if (from.name != to.name) return 'active model ${from.name} → ${to.name}';
    if (fromIdentity.modelType != identity.modelType) {
      return 'modelType ${fromIdentity.modelType.name} → '
          '${identity.modelType.name}';
    }
    if (fromIdentity.fileType != identity.fileType) {
      return 'fileType ${fromIdentity.fileType.name} → '
          '${identity.fileType.name}';
    }
    // Spec equality covers the rest: the source, the LoRA, the install
    // options. On mobile and desktop it also covers modelType and fileType,
    // which is why those are named first.
    if (from != to) {
      return '${to.name} re-installed with another source, LoRA or options';
    }
    final changed = fromParams.firstDifference(params);
    if (changed != null) return 'runtime config changed ($changed)';
    return null;
  }
}
