// The one path every shell (mobile, desktop, web) builds the active embedder
// through (R5 §4.2, §5.5). The shells keep only their platform wiring — the
// manager they own, the cache they own, the debug notice — and call this
// inside `EmbedderCache.serialize`, so resolving paths, deciding on reuse and
// building stay one indivisible step on every platform.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/model_management/active_embedding_identity.dart'
    show noActiveEmbedderError;
import 'package:flutter_edge_ai/src/model_file_manager_interface.dart'
    show ModelFileManager;
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

import 'common_embedding_model.dart';
import 'embedder_backend_notice.dart';
import 'embedder_cache.dart';
import 'embedding_exceptions.dart';
import 'embedding_modality.dart';
import 'embedding_model.dart';
import 'embedding_pass.dart' show EmbeddingPassDescriptor;
import 'installed_file_size.dart'
    if (dart.library.js_interop) 'installed_file_size_web.dart';

/// Returns the embedder for [manager]'s active embedding spec — the cached one
/// when it serves the request, else a new one built through the registered
/// backend and recorded in [cache]. Run it inside [EmbedderCache.serialize].
///
/// [supportImage] / [supportAudio] declare the media the caller will send;
/// text is implied whenever the model has a text tower. A rebuild widens them
/// to everything the cached embedder already served (R5 §4.6).
///
/// [verifyInstalled] re-checks that the active spec's files are still
/// installed before building (the mobile shell's long-standing check).
///
/// [entryPoint] is the shell's own `createEmbeddingModel`. A model built here
/// keeps a call to it, with this call's backend and the build's media, as
/// its `replacement`: a decider created from the model takes the embedder
/// core serves in its place when the model is closed, under the cache's
/// reuse rule like any other caller.
///
/// Throws [StateError] when no embedding spec is active or its files cannot be
/// resolved, or when no registered backend can run it;
/// [EmbeddingLoadException] when the backend refuses the request or the model
/// fails to load; [EmbedderCloseTimeoutException] when the embedder it
/// replaces is still closing after the cache's bound. A failure before the
/// build (the files gone, no backend, `describe()` refusing) leaves the cached
/// embedder open and cached; a failure of the new pass's load comes after the
/// cached embedder was closed.
Future<EmbeddingModel> loadActiveEmbedder({
  required ModelFileManager manager,
  required EmbedderCache cache,
  required PreferredBackend? preferredBackend,
  required bool supportImage,
  required bool supportAudio,
  required Future<EmbeddingModel> Function({
    PreferredBackend? preferredBackend,
    bool supportImage,
    bool supportAudio,
  })
  entryPoint,
  bool verifyInstalled = false,
}) async {
  final active = manager.activeEmbeddingModel;
  if (active == null) throw noActiveEmbedderError();
  if (active is! EmbeddingModelSpec) {
    throw StateError(
      'The active embedding slot holds a ${active.runtimeType}, not an '
      'EmbeddingModelSpec.',
    );
  }

  // §4.2 step 1: paths. A self-contained spec has no tokenizer, and its
  // tokenizerPath is null — never the model path.
  final paths = await manager.getModelFilePaths(active);
  if (paths == null || paths.isEmpty) {
    throw StateError(
      'The files of the active embedding model (${active.name}) were not '
      'found. Install it with `FlutterEdgeAi.installEmbedder()` first.',
    );
  }
  final modelPath =
      paths[PreferencesKeys.embeddingModelFile] ??
      (throw StateError(
        'Could not find the model path of the active embedding model '
        '(${active.name}).',
      ));
  final tokenizerPath = active.isSelfContained
      ? null
      : (paths[PreferencesKeys.embeddingTokenizerFile] ??
            (throw StateError(
              'Could not find the tokenizer path of the active embedding '
              'model (${active.name}).',
            )));
  edgeAiLog(
    'Using active embedding model: $modelPath'
    '${tokenizerPath == null ? '' : ', tokenizer: $tokenizerPath'}',
  );

  final backends = EmbeddingRegistry.instance;
  final backend = backends.findFor(active);
  if (backend == null) {
    throw StateError(
      backends.hasAny
          ? 'No registered embedding backend can run '
                '${active.files.first.filename}. Registered backends: '
                '${backends.registered.map((b) => b.name).join(', ')}.'
          : 'No embedding backend registered. Add flutter_edge_ai_litertlm '
                'to pubspec.yaml and pass LiteRtEmbeddingBackend() in '
                'embeddingBackends: of FlutterEdgeAi.initialize(...).',
    );
  }
  // These notices describe legacy providers only. GPU-capable providers
  // preserve the request and report their actual accelerator after loading.
  if (backend.cacheBackend(PreferredBackend.gpu) == PreferredBackend.cpu) {
    if (kIsWeb) {
      noticeWebEmbedderBackendIgnored(preferredBackend);
    } else {
      noticeEmbedderBackendIgnored(preferredBackend);
    }
  }

  // Steps 2–3: the cache decides — reuse, or what to build (widened media) —
  // and, for a build, the backend describes the pass BEFORE the cached
  // embedder is closed. A request the backend refuses (media an engine has no
  // tower for, a model it cannot run) therefore costs the app nothing: the
  // cached embedder stays and keeps serving what it served. A refusal only
  // the pass's load() can make (a `.litertlm` bundle with no tower for a
  // declared medium, read from the bundle itself) still costs a reload — by
  // then the cached embedder is closed.
  final requested = ActiveEmbedderParams(
    modelPath: modelPath,
    tokenizerPath: tokenizerPath,
    preferredBackend: backend.cacheBackend(preferredBackend),
    normalizeBackend: false,
    media: {
      if (supportImage) EmbeddingModality.image,
      if (supportAudio) EmbeddingModality.audio,
    },
  );
  EmbeddingPassDescriptor<Object>? described;
  final decision = await cache.reuseOrInvalidate(
    requested,
    label: active.name,
    prepare: (build) async {
      if (verifyInstalled && !await manager.isModelInstalled(active)) {
        throw StateError(
          'The active embedding model (${active.name}) is no longer '
          'installed. Install it again with `FlutterEdgeAi.installEmbedder()`.',
        );
      }
      final config = RuntimeConfig(
        maxTokens: 0,
        modelPath: build.modelPath,
        tokenizerPath: build.tokenizerPath,
        preferredBackend: preferredBackend,
        supportImage: build.media.contains(EmbeddingModality.image),
        supportAudio: build.media.contains(EmbeddingModality.audio),
      );
      described = await _asLoadFailure(
        backend.name,
        'could not describe a pass for',
        build.modelPath,
        () => backend.describe(active, config),
      );
    },
  );
  final reused = decision.reuse;
  if (reused != null) {
    noticeEmbedderNpuNotApplied(preferredBackend, reused.activeBackend);
    return reused;
  }
  final build = decision.build;
  final descriptor =
      described ??
      (throw StateError(
        'The embedder cache decided a build it never let the '
        'loader prepare.',
      ));

  try {
    // Step 4: core builds, hosts and checks the pass.
    // A pass whose load fails is closed behind the error; the cache holds
    // the next build until that close has ended (never two engines).
    final EmbeddingModel model = await CommonEmbeddingModel.start(
      descriptor,
      declaredMedia: build.media,
      label: modelPath,
      installedFiles: [
        for (final file in active.files)
          (
            name: file.filename,
            bytes: switch (paths[file.prefsKey]) {
              final path? => await installedFileSize(path),
              null => null,
            },
          ),
      ],
      replacement: () => entryPoint(
        preferredBackend: preferredBackend,
        supportImage: build.media.contains(EmbeddingModality.image),
        supportAudio: build.media.contains(EmbeddingModality.audio),
      ),
      onFailedLoadCleanup: (cleanup) =>
          cache.trackFailedLoadCleanup(cleanup, build),
    );

    // Core owns the lifecycle: the cache tracks the model, forgets it when it
    // closes (identity-guarded) and records what it was built from.
    await cache.adopt(model, build);
    noticeEmbedderNpuNotApplied(preferredBackend, model.activeBackend);
    return model;
  } catch (_) {
    // FIX #170: leave no bookkeeping behind, so a retry is a fresh decision
    // rather than a replay of this failure.
    cache.invalidate();
    rethrow;
  }
}

/// Runs a backend's [step]; anything it throws other than an
/// `EmbeddingLoadException` reaches the app as one — as `getActiveEmbedder`
/// documents — with the original error as its cause and its stack kept.
Future<T> _asLoadFailure<T>(
  String engine,
  String doing,
  String label,
  Future<T> Function() step,
) async {
  try {
    return await step();
  } on EmbeddingLoadException {
    rethrow;
  } catch (e, st) {
    Error.throwWithStackTrace(
      EmbeddingLoadException(
        '$engine $doing $label: $e',
        engine: engine,
        cause: e,
      ),
      st,
    );
  }
}
