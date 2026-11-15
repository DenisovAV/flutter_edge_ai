import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/src/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show ModelManagementType;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

/// Holds Hugging Face manifest resolvers registered via
/// `FlutterEdgeAi.initialize`. Selection is by role first — only resolvers
/// whose [HuggingFaceResolver.type] is the role asked for take part — then
/// the same probe chain as [EngineRegistry]: the resolver with the highest
/// [HuggingFaceResolver.priority] whose [HuggingFaceResolver.canResolve] is
/// true wins (first-registered breaks ties). No central format map — a
/// resolver self-selects within its role.
class HuggingFaceResolverRegistry {
  HuggingFaceResolverRegistry._();
  static final HuggingFaceResolverRegistry instance =
      HuggingFaceResolverRegistry._();

  final _registered = <HuggingFaceResolver>[];

  void registerAll(List<HuggingFaceResolver> resolvers) {
    for (final r in resolvers) {
      if (!_registered.contains(r)) _registered.add(r);
    }
  }

  /// First resolver of role [type] (by descending priority, then registration
  /// order) whose [HuggingFaceResolver.canResolve] accepts [repo]; null if
  /// none. A resolver of another role is never asked.
  HuggingFaceResolver? findFor(
    String repo, {
    required ModelManagementType type,
    ModelFileType? fileType,
  }) {
    final matches = _registered
        .where((r) => r.type == type && r.canResolve(repo, fileType: fileType))
        .toList();
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
      edgeAiLog(
        '[flutter_edge_ai] Ambiguous ${type.name} HF resolver: '
        '${indexed.map((e) => e.$2.name).join(", ")} all handle "$repo" at '
        'priority ${indexed[0].$2.priority}; using "${indexed[0].$2.name}" '
        '(first registered).',
      );
    }
    return indexed.first.$2;
  }

  List<HuggingFaceResolver> get registered => List.unmodifiable(_registered);

  bool get hasAny => _registered.isNotEmpty;

  void reset() => _registered.clear();
}
