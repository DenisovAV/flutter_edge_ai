/// Provider-agnostic hybrid routing for Genkit.
///
/// `defineHybridRouter` adds a generate middleware that sends each call to
/// one of its targets (on-device or cloud) once, at the first turn of the
/// tool loop, by deterministic rules first and a classifier second. Cloud
/// plugins live only inside the router, so a call that skips it cannot reach
/// the cloud.
///
/// The 0.3 composite-model API (`hybridModel`, `cascadeModel`, the
/// `RoutingStrategy` family) is deprecated and is removed in 0.5.0.
library;

export 'src/model_capability.dart' show ModelCapability;
export 'src/router/hybrid_prompt.dart' show HybridPrompt;
export 'src/router/hybrid_router.dart' show HybridRouter, defineHybridRouter;
export 'src/router/hybrid_routing_exception.dart' show HybridRoutingException;
export 'src/router/hybrid_target.dart' show HybridTarget;
export 'src/router/route_classifier.dart'
    show
        AbstainVerdict,
        LabelVerdict,
        RouteClassifier,
        RouteClassifierUnavailableException,
        RouteVerdict;
export 'src/router/route_decision.dart' show RouteDecision;
export 'src/router/route_info.dart'
    show
        CloudConsent,
        CloudConsentRequest,
        HybridGenerateResult,
        RouteInfo,
        RouteSource;
export 'src/router/route_policy.dart' show CascadeCheck, RoutePolicy;
export 'src/router/route_request.dart' show RouteRequest;
export 'src/router/route_rule.dart' show RouteRule;

// Deprecated in 0.4.0, removed in 0.5.0.
export 'src/routing_context.dart';
export 'src/routing_strategy.dart';
export 'src/hybrid_model.dart'
    show hybridModel, hybridModelOnDeviceCloud, kOnDevice, kCloud;
export 'src/strategies/pre_routing.dart';
export 'src/strategies/fallback.dart';
export 'src/strategies/connectivity.dart';
export 'src/strategies/input_size.dart';
export 'src/strategies/first_match.dart';
export 'src/strategies/with_fallback.dart';
export 'src/strategies/capability.dart' show CapabilityStrategy;
export 'src/strategies/cost.dart';
export 'src/cascade_model.dart';
