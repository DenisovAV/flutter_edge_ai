import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/registry/skill_executor_provider.dart';

/// Holds skill executors registered via `FlutterGemma.initialize`
/// (`skillExecutors:`). Same probe-chain selection as `EngineRegistry` /
/// `EmbeddingRegistry`: the registered executor with the highest
/// [SkillExecutorProvider.priority] whose [SkillExecutorProvider.canExecute]
/// returns true for a skill type wins (first-registered breaks ties). There is
/// no central type map — the opt-in `flutter_gemma_agent` executors self-select.
///
/// Core owns only this registry + the [SkillExecutorProvider] contract; the
/// concrete `SkillExecutor` base and `SkillResult` types live in the agent
/// package, keeping core dependency-free.
class SkillExecutorRegistry {
  SkillExecutorRegistry._();
  static final SkillExecutorRegistry instance = SkillExecutorRegistry._();

  final _registered = <SkillExecutorProvider>[];

  void registerAll(List<SkillExecutorProvider> executors) {
    for (final e in executors) {
      if (!_registered.contains(e)) _registered.add(e);
    }
  }

  /// First executor (by descending priority, then registration order) whose
  /// [SkillExecutorProvider.canExecute] accepts [skillType]; null if none.
  SkillExecutorProvider? findFor(String skillType) {
    final matches = _registered.where((e) => e.canExecute(skillType)).toList();
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
        '[flutter_gemma] Ambiguous skill executor: '
        '${indexed.map((e) => e.$2.name).join(", ")} all handle "$skillType" at '
        'priority ${indexed[0].$2.priority}; using "${indexed[0].$2.name}" '
        '(first registered).',
      );
    }
    return indexed.first.$2;
  }

  List<SkillExecutorProvider> get registered => List.unmodifiable(_registered);

  bool get hasAny => _registered.isNotEmpty;

  void reset() => _registered.clear();
}
