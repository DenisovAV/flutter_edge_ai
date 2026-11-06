/// Provider-agnostic hybrid routing for Genkit.
///
/// `defineHybridRouter` adds a generate middleware that sends each call to
/// one of its targets (on-device or cloud) once, at the first turn of the
/// tool loop, by deterministic rules first and a classifier second. Cloud
/// plugins live only inside the router, so a call that skips it cannot reach
/// the cloud.
///
/// The 0.3 composite-model API was removed in 0.5.0.
library;

export 'src/model_capability.dart' show ModelCapability;
export 'src/router/hybrid_prompt.dart' show HybridPrompt;
export 'src/router/hybrid_router.dart' show HybridRouter, defineHybridRouter;
export 'src/router/hybrid_routing_exception.dart' show HybridRoutingException;
export 'src/router/hybrid_target.dart' show HybridTarget, kCloud, kOnDevice;
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
