import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;

/// Holds inference engines registered via `FlutterGemma.initialize`.
/// Selection is a probe-chain: the registered engine with the highest
/// [InferenceEngineProvider.priority] whose [InferenceEngineProvider.canHandle]
/// is true wins (first-registered breaks ties). No central file-type map —
/// third-party engines self-select.
class EngineRegistry {
  EngineRegistry._();
  static final EngineRegistry instance = EngineRegistry._();

  final _registered = <InferenceEngineProvider>[];

  void registerAll(List<InferenceEngineProvider> engines) {
    for (final e in engines) {
      if (!_registered.contains(e)) _registered.add(e);
    }
  }

  /// First engine (by descending priority, then registration order) whose
  /// [InferenceEngineProvider.canHandle] accepts [spec]; null if none.
  InferenceEngineProvider? findFor(InferenceModelSpec spec) {
    final matches = _registered.where((e) => e.canHandle(spec)).toList();
    if (matches.isEmpty) return null;
    // Composite-key sort (Dart's List.sort is NOT stable): descending priority,
    // then ascending original index so first-registered wins on equal priority.
    final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])];
    indexed.sort((a, b) {
      final byPriority = b.$2.priority.compareTo(a.$2.priority);
      return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
    });
    if (kDebugMode &&
        indexed.length > 1 &&
        indexed[0].$2.priority == indexed[1].$2.priority) {
      gemmaLog(
        '[flutter_gemma] Ambiguous: '
        '${indexed.map((e) => e.$2.name).join(", ")} all handle this spec at '
        'priority ${indexed[0].$2.priority}; using "${indexed[0].$2.name}" '
        '(first registered).',
      );
    }
    return indexed.first.$2;
  }

  List<InferenceEngineProvider> get registered =>
      List.unmodifiable(_registered);

  void reset() => _registered.clear();
}
