import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/models/model_catalog.dart';
import 'token_store.dart';

/// Where a catalog model is, from the app's point of view.
sealed class ModelStatus {
  const ModelStatus();
}

class NotInstalled extends ModelStatus {
  const NotInstalled();
}

class Downloading extends ModelStatus {
  const Downloading(this.percent);
  final int percent;
}

class Installed extends ModelStatus {
  const Installed();
}

class Loading extends ModelStatus {
  const Loading();
}

class Ready extends ModelStatus {
  const Ready();
}

class Failed extends ModelStatus {
  const Failed(this.message, {this.needsToken = false});
  final String message;

  /// True when the host answered 401/403: the fix is a token, not a retry.
  final bool needsToken;
}

/// Everything the app knows about models: which are installed, which is
/// loaded, and download progress. One instance owns the SDK lifecycle so no
/// other code touches `FlutterEdgeAi` directly (VA-1.1.1).
class ModelsState {
  const ModelsState({required this.statuses, this.activeId});

  final Map<String, ModelStatus> statuses;
  final String? activeId;

  ModelStatus statusOf(AdvisorModelSpec m) => statuses[m.id] ?? const NotInstalled();

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
  Future<void> initialize();
  Future<bool> isInstalled(AdvisorModelSpec spec);
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  });
  Future<void> uninstall(AdvisorModelSpec spec);
  Future<InferenceModel> load(AdvisorModelSpec spec);
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
  Future<InferenceModel> load(AdvisorModelSpec spec) async {
    // `getActiveModel` loads whichever model the SDK last marked active. Re-running
    // the install for an already-downloaded file is the SDK's way to mark it
    // active without copying (mirrors the upstream example's loader).
    await FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromNetwork(spec.url).install();
    return FlutterEdgeAi.getActiveModel(
      maxTokens: spec.maxTokens,
      preferredBackend: spec.preferredBackend,
    );
  }
}

final edgeAiGatewayProvider = Provider<EdgeAiGateway>((ref) => FlutterEdgeAiGateway());

final advisorModelServiceProvider = AsyncNotifierProvider<AdvisorModelService, ModelsState>(
  AdvisorModelService.new,
);

class AdvisorModelService extends AsyncNotifier<ModelsState> {
  InferenceModel? _loaded;
  CancelToken? _cancel;

  /// The loaded model, for the chat layer. Null until [activate] succeeds.
  InferenceModel? get loadedModel => _loaded;

  @override
  Future<ModelsState> build() async {
    final gateway = ref.watch(edgeAiGatewayProvider);
    await gateway.initialize();
    final statuses = <String, ModelStatus>{};
    for (final m in ModelCatalog.all) {
      statuses[m.id] = await gateway.isInstalled(m) ? const Installed() : const NotInstalled();
    }
    ref.onDispose(() => _loaded?.close());
    return ModelsState(statuses: statuses);
  }

  void _set(AdvisorModelSpec m, ModelStatus s) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(statuses: {...current.statuses, m.id: s}));
  }

  Future<void> download(AdvisorModelSpec m) async {
    final gateway = ref.read(edgeAiGatewayProvider);
    final token = await ref.read(tokenStoreProvider).read();
    _cancel = CancelToken();
    _set(m, const Downloading(0));
    try {
      await gateway.install(
        m,
        token: (token == null || token.isEmpty) ? null : token,
        onProgress: (p) => _set(m, Downloading(p)),
        cancelToken: _cancel,
      );
      _set(m, const Installed());
    } on DownloadException catch (e) {
      final text = e.toString();
      final needsToken = text.contains('401') || text.contains('403');
      _set(m, Failed(text, needsToken: needsToken));
    } catch (e) {
      _set(m, Failed(e.toString()));
    } finally {
      _cancel = null;
    }
  }

  void cancelDownload() => _cancel?.cancel();

  Future<void> remove(AdvisorModelSpec m) async {
    final current = state.value;
    if (current?.activeId == m.id) {
      await _loaded?.close();
      _loaded = null;
      state = AsyncData(current!.copyWith(clearActive: true));
    }
    await ref.read(edgeAiGatewayProvider).uninstall(m);
    _set(m, const NotInstalled());
  }

  /// Load [m] and make it the model the chat uses. Switching closes the
  /// previous model first (VA-1.2.1).
  Future<void> activate(AdvisorModelSpec m) async {
    final current = state.value;
    if (current == null) return;
    await _loaded?.close();
    _loaded = null;
    final statuses = {...current.statuses};
    if (current.activeId != null && current.activeId != m.id) {
      statuses[current.activeId!] = const Installed();
    }
    statuses[m.id] = const Loading();
    state = AsyncData(ModelsState(statuses: statuses));
    try {
      _loaded = await ref.read(edgeAiGatewayProvider).load(m);
      state = AsyncData(ModelsState(statuses: {...statuses, m.id: const Ready()}, activeId: m.id));
    } catch (e) {
      state = AsyncData(ModelsState(statuses: {...statuses, m.id: Failed(e.toString())}));
    }
  }
}
