import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/models/model_catalog.dart';
import 'log.dart';
import 'token_store.dart';

/// Where a catalog model is, from the app's point of view.
sealed class ModelStatus {
  const ModelStatus();
}

/// Not on the device.
final class ModelNotInstalled extends ModelStatus {
  const ModelNotInstalled();
}

/// Download in progress, with the percent so far.
final class ModelDownloading extends ModelStatus {
  const ModelDownloading(this.percent);

  final int percent;
}

/// On the device, not loaded into memory.
final class ModelInstalled extends ModelStatus {
  const ModelInstalled();
}

/// Being loaded into memory.
final class ModelLoading extends ModelStatus {
  const ModelLoading();
}

/// Loaded and answering.
final class ModelReady extends ModelStatus {
  const ModelReady();
}

/// A download or load failed; [message] is a sentence for the person.
final class ModelFailed extends ModelStatus {
  const ModelFailed(this.message, {this.needsToken = false});

  final String message;

  /// True when the host answered 401/403: the fix is a token, not a retry.
  final bool needsToken;
}

/// What the app knows about each catalog model, and which one is active.
class ModelsState {
  const ModelsState({required this.statuses, this.activeId});

  final Map<String, ModelStatus> statuses;
  final String? activeId;

  ModelStatus statusOf(AdvisorModelSpec m) => statuses[m.id] ?? const ModelNotInstalled();

  ModelsState copyWith({
    Map<String, ModelStatus>? statuses,
    String? activeId,
    bool clearActive = false,
  }) => ModelsState(
    statuses: statuses ?? this.statuses,
    activeId: clearActive ? null : (activeId ?? this.activeId),
  );
}

/// The SDK seam. The real implementation calls `FlutterEdgeAi`; tests supply
/// a fake so the notifier's state machine is testable on the Dart VM.
abstract class EdgeAiGateway {
  /// Starts the engine once; later calls are no-ops.
  Future<void> initialize();

  /// Whether the model's file is on the device.
  Future<bool> isInstalled(AdvisorModelSpec spec);

  /// Downloads the model, reporting whole percents; [token] for gated hosts.
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  });

  /// Deletes the model's file.
  Future<void> uninstall(AdvisorModelSpec spec);

  /// Loads an installed model into memory and returns it.
  Future<InferenceModel> load(AdvisorModelSpec spec, {String? token});
}

class FlutterEdgeAiGateway implements EdgeAiGateway {
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
    _initialized = true;
  }

  @override
  Future<bool> isInstalled(AdvisorModelSpec spec) => FlutterEdgeAi.isModelInstalled(spec.filename);

  @override
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  }) async {
    var builder = FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromNetwork(spec.url, token: token, foreground: true).withProgress(onProgress);
    if (cancelToken != null) builder = builder.withCancelToken(cancelToken);
    await builder.install();
  }

  @override
  Future<void> uninstall(AdvisorModelSpec spec) => FlutterEdgeAi.uninstallModel(spec.filename);

  @override
  Future<InferenceModel> load(AdvisorModelSpec spec, {String? token}) async {
    // `getActiveModel` loads whichever model the SDK last marked active. Re-running
    // the install for an already-downloaded file is the SDK's way to mark it
    // active without copying (mirrors the upstream example's loader). The
    // token rides along so a gated model can be marked active too.
    await FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromNetwork(spec.url, token: token).install();
    final maxTokens = await contextWindowFor(spec);
    return FlutterEdgeAi.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: spec.preferredBackend,
    );
  }
}

final edgeAiGatewayProvider = Provider<EdgeAiGateway>((ref) => FlutterEdgeAiGateway());

final advisorModelServiceProvider = AsyncNotifierProvider<AdvisorModelService, ModelsState>(
  AdvisorModelService.new,
);

/// One instance owns the SDK lifecycle: downloads, the loaded model and the
/// switch between models. No other code touches `FlutterEdgeAi` directly
/// (backlog VA-1.1.1).
class AdvisorModelService extends AsyncNotifier<ModelsState> {
  /// Sentences for the person; the engine's own text goes to the log.
  static const _downloadFailed = 'The download failed. Check the connection and retry.';
  static const _loadFailed = 'The model could not be loaded. Free some memory and retry.';
  static const _notInstalled = 'Download the model first.';

  InferenceModel? _loaded;

  /// Cancel tokens per model id, so cancelling one download never hits
  /// another.
  final Map<String, CancelToken> _cancels = {};

  /// The loaded model, for the chat layer. Null until [activate] succeeds.
  InferenceModel? get loadedModel => _loaded;

  @override
  Future<ModelsState> build() async {
    final gateway = ref.watch(edgeAiGatewayProvider);
    await gateway.initialize();
    final statuses = <String, ModelStatus>{};
    for (final m in ModelCatalog.all) {
      statuses[m.id] = await gateway.isInstalled(m)
          ? const ModelInstalled()
          : const ModelNotInstalled();
    }
    // Closing at teardown is fire-and-forget: nothing can await a disposed
    // notifier.
    ref.onDispose(() => unawaited(_loaded?.close() ?? Future.value()));
    return ModelsState(statuses: statuses);
  }

  void _set(AdvisorModelSpec m, ModelStatus s) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(statuses: {...current.statuses, m.id: s}));
  }

  /// Downloads [m]; a second call while it is downloading is ignored.
  Future<void> download(AdvisorModelSpec m) async {
    if (_cancels.containsKey(m.id)) return;
    final gateway = ref.read(edgeAiGatewayProvider);
    final token = await _token();
    final cancel = _cancels[m.id] = CancelToken();
    _set(m, const ModelDownloading(0));
    try {
      await gateway.install(
        m,
        token: token,
        onProgress: (p) => _set(m, ModelDownloading(p)),
        cancelToken: cancel,
      );
      _set(m, const ModelInstalled());
    } on DownloadException catch (e) {
      // 401 and 403 mean a token, not a retry, is the fix.
      final needsToken = e.error is UnauthorizedError || e.error is ForbiddenError;
      logDev('download of ${m.id} failed: $e');
      _set(m, ModelFailed(_downloadFailed, needsToken: needsToken));
    } on Exception catch (e) {
      logDev('download of ${m.id} failed: $e');
      _set(m, cancel.isCancelled ? const ModelNotInstalled() : const ModelFailed(_downloadFailed));
    } finally {
      _cancels.remove(m.id);
    }
  }

  /// Stops the download of [m]; its status returns to not installed.
  void cancelDownload(AdvisorModelSpec m) => _cancels[m.id]?.cancel();

  Future<String?> _token() async {
    final token = await ref.read(tokenStoreProvider).read();
    return (token == null || token.isEmpty) ? null : token;
  }

  Future<void> remove(AdvisorModelSpec m) async {
    final current = state.value;
    if (current?.activeId == m.id) {
      await _loaded?.close();
      _loaded = null;
      state = AsyncData(current!.copyWith(clearActive: true));
    }
    await ref.read(edgeAiGatewayProvider).uninstall(m);
    _set(m, const ModelNotInstalled());
  }

  /// Loads [m] and makes it the model the chat uses. Switching closes the
  /// previous model first (backlog VA-1.2.1). Only an installed model can be
  /// activated.
  Future<void> activate(AdvisorModelSpec m) async {
    final current = state.value;
    if (current == null) return;
    final status = current.statusOf(m);
    if (status is! ModelInstalled && status is! ModelReady && status is! ModelFailed) {
      _set(m, const ModelFailed(_notInstalled));
      return;
    }
    await _loaded?.close();
    _loaded = null;
    final statuses = {...current.statuses};
    if (current.activeId != null && current.activeId != m.id) {
      statuses[current.activeId!] = const ModelInstalled();
    }
    statuses[m.id] = const ModelLoading();
    state = AsyncData(ModelsState(statuses: statuses));
    try {
      _loaded = await ref.read(edgeAiGatewayProvider).load(m, token: await _token());
      state = AsyncData(
        ModelsState(statuses: {...statuses, m.id: const ModelReady()}, activeId: m.id),
      );
    } on Exception catch (e) {
      logDev('load of ${m.id} failed: $e');
      state = AsyncData(ModelsState(statuses: {...statuses, m.id: const ModelFailed(_loadFailed)}));
    }
  }
}

/// Free memory below which the catalog's window is cut to [_safeWindow],
/// and below which again to [_minimalWindow]. Emulator-era numbers: a 6 GB
/// emulator running Gemma 4 E2B with an 8k window plus a WebView reached
/// 4.8 GB resident and the OS killed the app.
const _comfortableFreeGb = 5.5;
const _tightFreeGb = 3.0;
const _safeWindow = 4096;
const _minimalWindow = 2048;

/// The context window is memory: the KV cache grows with it. The catalog
/// value is a ceiling, and a device with less room gets a smaller window.
/// Exposed for the gateway and for tests of the thresholds.
Future<int> contextWindowFor(AdvisorModelSpec spec) async {
  var window = spec.maxTokens;
  try {
    if (FlutterEdgeAiDiagnostics.isSupported) {
      final snap = await FlutterEdgeAiDiagnostics.memorySnapshot();
      final available = snap.availableBytes;
      if (available != null) {
        final gb = available / (1024 * 1024 * 1024);
        window = windowForFreeMemory(gb, ceiling: window);
        logDev('available memory ${gb.toStringAsFixed(1)} GB -> context $window');
      }
    }
  } on Exception catch (e) {
    logDev('memory snapshot failed: $e');
  }
  return window;
}

/// The pure part of [contextWindowFor]: the window for [freeGb] of free
/// memory, never above [ceiling].
int windowForFreeMemory(double freeGb, {required int ceiling}) {
  var window = ceiling;
  if (freeGb < _comfortableFreeGb && window > _safeWindow) window = _safeWindow;
  if (freeGb < _tightFreeGb && window > _minimalWindow) window = _minimalWindow;
  return window;
}
