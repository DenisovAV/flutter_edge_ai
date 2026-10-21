import 'package:genkit/genkit.dart';

import '../model_capability.dart';

/// The key of the on-device target. An abstain and a resume without the
/// router's stamp go to it, `RouteRule.offline` defaults to it, and it must
/// hold an on-device target. The 0.3 façade's branch key too.
const String kOnDevice = 'onDevice';

/// The usual key of the cloud target; the 0.3 façade's branch key too.
const String kCloud = 'cloud';

/// A model the router can send a request to.
final class HybridTarget {
  /// A model registered in the app's Genkit, e.g. an on-device model of
  /// genkit_flutter_edge_ai. The router calls it directly.
  const HybridTarget.onDevice(this.model, {this.supports}) : isCloud = false;

  /// A model one of the router's `cloudPlugins` resolves. The app's Genkit
  /// never sees it: the router registers a proxy there that serves a request
  /// only when the router chose this target.
  const HybridTarget.cloud(this.model, {this.supports}) : isCloud = true;

  /// The model, with the `config` this target runs with. The caller's call
  /// passes no config: each target owns its own.
  final ModelRef model;

  /// Whether this target runs in the cloud.
  final bool isCloud;

  /// What the model can do. Null means not declared: the router does not
  /// filter this target by capability.
  final Set<ModelCapability>? supports;
}

/// Whether [target] can serve a request that needs [required]. Not exported.
bool canServe(HybridTarget target, Set<ModelCapability> required) =>
    target.supports?.containsAll(required) ?? true;

/// [target] with its own unmodifiable copy of `supports`. Not exported.
HybridTarget frozenTarget(HybridTarget target) {
  final supports = switch (target.supports) {
    final s? => Set<ModelCapability>.unmodifiable(s),
    null => null,
  };
  return target.isCloud
      ? HybridTarget.cloud(target.model, supports: supports)
      : HybridTarget.onDevice(target.model, supports: supports);
}
