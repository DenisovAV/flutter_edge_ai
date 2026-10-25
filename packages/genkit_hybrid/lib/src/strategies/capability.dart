import 'package:genkit/genkit.dart';

import '../media_kind.dart';
import '../model_capability.dart';
import '../routing_context.dart';
import '../routing_strategy.dart';

export '../model_capability.dart';

/// Routes to branches that support what the request requires (media, tools,
/// JSON output), preferring [order]. Returns capable branches only, or `[]`
/// ("no decision") when none qualifies — compose with `WithFallback`
/// for a best-effort attempt on a non-capable branch.
///
/// Capabilities are declared explicitly in [supports], NOT read from a
/// branch's Genkit `metadata['model']['supports']`: that map is untyped, often
/// absent, and its `media` flag does not split vision from audio. The default
/// [order] is `supports.keys` in insertion order. `ModelCapability` is safe to
/// grow (callers build sets, never `switch`).
///
/// v1 blind spots: `video/*` media, PDFs, `request.docs`, and a hosted media
/// URL with neither a `contentType` nor a recognized file extension all map to
/// no required capability.
@Deprecated(
  'Use HybridTarget.supports on a defineHybridRouter target; '
  'removed in 0.5.0.',
)
class CapabilityStrategy implements RoutingStrategy {
  CapabilityStrategy({
    required Map<String, Set<ModelCapability>> supports,
    List<String>? order,
  }) : _supports = {
         for (final e in supports.entries) e.key: Set.unmodifiable(e.value),
       },
       _order = List.unmodifiable(order ?? supports.keys) {
    if (order != null) {
      for (final k in order) {
        if (!supports.containsKey(k)) {
          throw ArgumentError.value(
            order,
            'order',
            'key "$k" is not in supports (${supports.keys.join(', ')})',
          );
        }
      }
    }
  }

  final Map<String, Set<ModelCapability>> _supports;
  final List<String> _order;

  @override
  List<String> route(RoutingContext context) {
    final required = _required(context.request);
    return _order
        .where((k) => (_supports[k] ?? const {}).containsAll(required))
        .toList();
  }

  Set<ModelCapability> _required(ModelRequest? request) {
    if (request == null) return const {};
    final caps = mediaCapabilities(request.messages);
    if (request.tools?.isNotEmpty ?? false) caps.add(ModelCapability.tools);
    final o = request.output;
    if (o != null &&
        (o.format == 'json' ||
            o.schema != null ||
            o.contentType == 'application/json')) {
      caps.add(ModelCapability.json);
    }
    return caps;
  }
}
