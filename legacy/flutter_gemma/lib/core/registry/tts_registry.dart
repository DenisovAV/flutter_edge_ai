import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/registry/tts_backend_provider.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelSpec;

/// Holds TTS backends registered via `FlutterGemma.initialize`.
/// Same probe-chain selection as `EmbeddingRegistry`/`EngineRegistry`.
class TtsRegistry {
  TtsRegistry._();
  static final TtsRegistry instance = TtsRegistry._();

  final _registered = <TtsBackendProvider>[];

  void registerAll(List<TtsBackendProvider> backends) {
    for (final b in backends) {
      if (!_registered.contains(b)) _registered.add(b);
    }
  }

  TtsBackendProvider? findFor(TtsModelSpec spec) {
    final matches = _registered.where((b) => b.canHandle(spec)).toList();
    if (matches.isEmpty) return null;
    final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])];
    indexed.sort((a, b) {
      final byPriority = b.$2.priority.compareTo(a.$2.priority);
      return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
    });
    if (kDebugMode &&
        indexed.length > 1 &&
        indexed[0].$2.priority == indexed[1].$2.priority) {
      gemmaLog(
        '[flutter_gemma] Ambiguous TTS backend: '
        '${indexed.map((e) => e.$2.name).join(", ")} all handle this spec at '
        'priority ${indexed[0].$2.priority}; using "${indexed[0].$2.name}".',
      );
    }
    return indexed.first.$2;
  }

  List<TtsBackendProvider> get registered => List.unmodifiable(_registered);

  bool get hasAny => _registered.isNotEmpty;

  void reset() => _registered.clear();
}
