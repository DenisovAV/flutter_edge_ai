import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:schemantic/schemantic.dart';

import '../attempts.dart' show isTransient;
import 'hybrid_prompt.dart';
import 'hybrid_routing_exception.dart';
import 'hybrid_target.dart';
import 'route_classifier.dart';
import 'route_decision.dart';
import 'route_info.dart';
import 'route_policy.dart';
import 'route_request.dart';
import 'route_rule.dart';

/// Zone key of the router's decision: a [_ZoneDecision] while an attempt of
/// a routed call runs, null inside a tool of one. Private to this library,
/// so nothing else can fake a decision.
final Object _decisionKey = Object();

final class _ZoneDecision {
  _ZoneDecision(this.middleware, this.target);

  final _RouterMiddleware middleware;
  final String target;

  /// False once the attempt it was made for has ended, so a zone kept from
  /// it (a stored `Zone`, a timer) no longer authorises anything.
  bool active = true;
}

/// The decision in force in the current zone, if any.
_ZoneDecision? _currentDecision() => switch (Zone.current[_decisionKey]) {
  final _ZoneDecision d when d.active => d,
  _ => null,
};

/// The key of the decision stamped on an interrupted model message.
const _stampKey = 'hybrid';

/// Defines a hybrid router in [ai] and returns it.
///
/// Registers in [ai] one generate middleware named [name] and, per cloud
/// target, a proxy model `<name>/<targetKey>` that serves a request only when
/// this router chose that target. The [cloudPlugins] go into a private Genkit
/// instance the app's [ai] never sees, so a call that skips the router cannot
/// reach the cloud: it names no model and [ai] has no default one, so Genkit
/// fails it.
///
/// Throws [ArgumentError] when [ai] has a default model, [name] is taken,
/// [targets] or [policies] is empty, a policy names an unknown target, a
/// policy with a classifier has no abstain target, a cascade has no fallback,
/// or a cloud target has no [cloudPlugins].
HybridRouter defineHybridRouter(
  Genkit ai, {
  String name = 'hybrid-router',
  required Map<String, HybridTarget> targets,
  List<GenkitPlugin> cloudPlugins = const [],
  required Map<String, RoutePolicy> policies,
  required String defaultPolicy,
  CloudConsent? confirmCloud,
}) => HybridRouter._define(
  ai,
  name: name,
  targets: targets,
  cloudPlugins: cloudPlugins,
  policies: policies,
  defaultPolicy: defaultPolicy,
  confirmCloud: confirmCloud,
);

/// Routes each generate call to one of its targets, once, at the first turn
/// of the tool loop, and keeps it there for the whole loop.
///
/// Use [generate], [generateStream] or [definePrompt]; they put the router
/// first in `use:` and throw [HybridRoutingException] when it refuses. In a
/// plain `ai.generate` or a `.prompt` file, put [call]'s ref first in `use:`.
final class HybridRouter {
  HybridRouter._define(
    this._ai, {
    required this.name,
    required Map<String, HybridTarget> targets,
    required List<GenkitPlugin> cloudPlugins,
    required Map<String, RoutePolicy> policies,
    required this.defaultPolicy,
    this._confirmCloud,
  }) : targets = Map.unmodifiable({
         for (final MapEntry(:key, :value) in targets.entries)
           key: frozenTarget(value),
       }),
       policies = Map.unmodifiable({
         for (final MapEntry(:key, :value) in policies.entries)
           key: frozenPolicy(value),
       }) {
    _validate(cloudPlugins);
    if (targets.values.any((t) => t.isCloud)) {
      // No reflection server (the Dev UI would list the cloud models), no
      // prompt folder (the app's prompts would load into it). Never shut
      // down: Genkit.shutdown disposes the process-wide instrumentation.
      _cloudAi = Genkit(
        plugins: cloudPlugins,
        isDevEnv: false,
        promptDir: null,
      );
    }
    _ai.defineGenerateMiddleware<Map<String, dynamic>>(
      name: name,
      create: (config, ctx) => _RouterMiddleware(this, config, ctx.ai),
    );
    for (final MapEntry(:key, :value) in this.targets.entries) {
      if (!value.isCloud) continue;
      _proxies[key] = _ai.defineModel(
        name: _proxyName(key),
        fn: (request, ctx) => _serveProxy(key, request, ctx),
      );
    }
  }

  final Genkit _ai;

  /// The private Genkit of the cloud plugins; set when there is a cloud
  /// target, and read only by a cloud target's proxy.
  late final Genkit _cloudAi;
  final Map<String, Model> _proxies = {};

  /// Target key → its config as JSON text, encoded once at definition.
  final Map<String, String> _configJson = {};

  /// The last lookup in the private Genkit. Lookups run one after another:
  /// its registry initialises a plugin on every lookup that starts before
  /// the first one finished.
  Future<void> _cloudLookups = Future.value();
  final CloudConsent? _confirmCloud;

  /// The middleware's name in the app's Genkit.
  final String name;

  /// Target key → target.
  final Map<String, HybridTarget> targets;

  /// Policy name → policy.
  final Map<String, RoutePolicy> policies;

  /// The policy a call that names none uses.
  final String defaultPolicy;

  String _proxyName(String key) => '$name/$key';

  void _validate(List<GenkitPlugin> cloudPlugins) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if (_ai.registry.lookupValue<ModelRef>('defaultModel', 'defaultModel') !=
        null) {
      throw ArgumentError(
        'The Genkit instance has a default model: a call that forgets the '
        'router would go there. Create Genkit without `model:` in a hybrid '
        'app.',
      );
    }
    if (_ai.registry.lookupValue<GenerateMiddlewareDef>('middleware', name) !=
        null) {
      throw ArgumentError.value(name, 'name', 'a middleware has this name');
    }
    if (targets.isEmpty) {
      throw ArgumentError.value(targets, 'targets', 'must not be empty');
    }
    for (final MapEntry(:key, :value) in targets.entries) {
      if (key.isEmpty) {
        throw ArgumentError.value(key, 'targets', 'a key must not be empty');
      }
      if (_encodeConfig(key, value.model.config) case final json?) {
        _configJson[key] = json;
      }
    }
    if (targets[kOnDevice]?.isCloud ?? false) {
      throw ArgumentError.value(
        kOnDevice,
        'targets',
        'must be an on-device target: an abstain and a resume without a '
            'stamp go there',
      );
    }
    if (targets.values.any((t) => t.isCloud) && cloudPlugins.isEmpty) {
      throw ArgumentError(
        'A cloud target needs the plugin that resolves it in `cloudPlugins`.',
      );
    }
    if (!policies.containsKey(defaultPolicy)) {
      throw ArgumentError.value(
        defaultPolicy,
        'defaultPolicy',
        'is not in policies (${policies.keys.join(', ')})',
      );
    }
    for (final MapEntry(key: policyName, value: p) in policies.entries) {
      void check(String target, String where) {
        if (!targets.containsKey(target)) {
          throw ArgumentError(
            'Policy "$policyName": $where names target "$target", which is '
            'not in targets (${targets.keys.join(', ')}).',
          );
        }
      }

      for (final rule in p.rules) {
        for (final t in builtInRuleTargets(rule) ?? const <String>{}) {
          check(t, 'rule "${rule.name}"');
        }
      }
      for (final MapEntry(:key, :value) in p.labels.entries) {
        check(value.target, 'label "$key"');
      }
      if (p.onAbstain case final d?) check(d.target, 'onAbstain');
      if (p.onUnavailable case final d?) check(d.target, 'onUnavailable');
      for (final t in p.fallback) {
        check(t, 'fallback');
      }
      if (p.fallback.toSet().length != p.fallback.length) {
        throw ArgumentError(
          'Policy "$policyName": fallback names a target twice '
          '(${p.fallback.join(', ')}).',
        );
      }
      if (p.classifier != null &&
          p.onAbstain == null &&
          !targets.containsKey(kOnDevice)) {
        throw ArgumentError(
          'Policy "$policyName" has a classifier but no onAbstain, and there '
          'is no "$kOnDevice" target to abstain to.',
        );
      }
      if (p.cascade != null && p.fallback.isEmpty) {
        throw ArgumentError(
          'Policy "$policyName" has a cascade but no fallback to escalate to.',
        );
      }
    }
  }

  /// Warms every policy's classifier (each once, however many policies share
  /// it) and every target with a `warmUp`, all at once, so the first request
  /// waits for none of them; start it when the app starts. Completes when
  /// all have ended, with the first failure if one failed: a failed warm-up
  /// is not hidden, and the request that needs it tries again.
  Future<void> warmUp() async {
    final classifiers = Set<RouteClassifier>.identity()
      ..addAll([for (final p in policies.values) ?p.classifier]);
    await Future.wait([
      for (final c in classifiers) Future.sync(c.warmUp),
      for (final t in targets.values)
        if (t.warmUp case final warmUp?) Future.sync(() => warmUp(t.model)),
    ]);
  }

  /// A ref to this router for `use:`, which must put it first. [policy] and
  /// [pin] name one of [policies] and of [targets]; a pin sends the call to
  /// that target only, skipping rules and classifier.
  GenerateMiddlewareRef<Map<String, dynamic>> call({
    String? policy,
    String? pin,
  }) {
    if (policy != null && !policies.containsKey(policy)) {
      throw ArgumentError.value(policy, 'policy', 'is not in policies');
    }
    if (pin != null && !targets.containsKey(pin)) {
      throw ArgumentError.value(pin, 'pin', 'is not in targets');
    }
    return middlewareRef<Map<String, dynamic>>(
      name: name,
      config: {'policy': ?policy, 'pin': ?pin},
    );
  }

  /// `ai.generate` routed by this router: every parameter of it except
  /// `model` and `config` (each target owns its own), plus [policy] and
  /// [pin]. Throws [HybridRoutingException] when the router refuses; other
  /// failures stay Genkit's `failed` results.
  Future<GenerateResult<Output>> generate<Output>({
    String? policy,
    String? pin,
    String? system,
    String? prompt,
    List<Part>? promptParts,
    List<Message>? messages,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    bool? returnToolRequests,
    int? maxTurns,
    SchemanticType<Output>? outputSchema,
    String? outputFormat,
    bool? outputConstrained,
    String? outputInstructions,
    bool? outputNoInstructions,
    String? outputContentType,
    Map<String, dynamic>? context,
    StreamingCallback<GenerateResponseChunk<Output>>? onChunk,
    List<GenerateMiddlewareRef>? use,
    CancellationToken? cancel,
    List<InterruptResponse>? interruptRespond,
    List<ToolRequestPart>? interruptRestart,
  }) async {
    final owner = Object();
    final result = await inRoutedCall(
      owner,
      () => _ai.generate<Output, Object?>(
        system: system,
        prompt: prompt,
        promptParts: promptParts,
        messages: messages,
        tools: tools,
        toolNames: toolNames,
        toolChoice: toolChoice,
        returnToolRequests: returnToolRequests,
        maxTurns: maxTurns,
        outputSchema: outputSchema,
        outputFormat: outputFormat,
        outputConstrained: outputConstrained,
        outputInstructions: outputInstructions,
        outputNoInstructions: outputNoInstructions,
        outputContentType: outputContentType,
        context: context,
        onChunk: onChunk,
        use: [
          call(policy: policy, pin: pin),
          ...?use,
        ],
        cancel: cancel,
        interruptRespond: interruptRespond,
        interruptRestart: interruptRestart,
      ),
    );
    return checkedRoutingResult(result, owner);
  }

  /// `ai.generateStream` routed by this router; see [generate]. A refusal
  /// fails both the chunk stream and `onResult`.
  ActionStream<GenerateResponseChunk<Output>, GenerateResult<Output>>
  generateStream<Output>({
    String? policy,
    String? pin,
    String? system,
    String? prompt,
    List<Part>? promptParts,
    List<Message>? messages,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    bool? returnToolRequests,
    int? maxTurns,
    SchemanticType<Output>? outputSchema,
    String? outputFormat,
    bool? outputConstrained,
    String? outputInstructions,
    bool? outputNoInstructions,
    String? outputContentType,
    Map<String, dynamic>? context,
    List<GenerateMiddlewareRef>? use,
    CancellationToken? cancel,
    List<InterruptResponse>? interruptRespond,
    List<ToolRequestPart>? interruptRestart,
  }) {
    final chunks = StreamController<GenerateResponseChunk<Output>>();
    final result = generate<Output>(
      policy: policy,
      pin: pin,
      system: system,
      prompt: prompt,
      promptParts: promptParts,
      messages: messages,
      tools: tools,
      toolNames: toolNames,
      toolChoice: toolChoice,
      returnToolRequests: returnToolRequests,
      maxTurns: maxTurns,
      outputSchema: outputSchema,
      outputFormat: outputFormat,
      outputConstrained: outputConstrained,
      outputInstructions: outputInstructions,
      outputNoInstructions: outputNoInstructions,
      outputContentType: outputContentType,
      context: context,
      use: use,
      cancel: cancel,
      interruptRespond: interruptRespond,
      interruptRestart: interruptRestart,
      onChunk: (chunk) {
        if (!chunks.isClosed) chunks.add(chunk);
      },
    );
    result.then(
      (_) => chunks.close(),
      onError: (Object e, StackTrace s) {
        chunks.addError(e, s);
        chunks.close();
      },
    );
    return ActionStream.withResult(chunks.stream, result);
  }

  /// `ai.definePrompt` routed by this router: every parameter of it except
  /// `model` and `config`, plus [policy] and [pin], fixed for this prompt.
  /// The registered prompt has this router first in its `use:`, so a Dev UI
  /// run of it is routed too.
  HybridPrompt<Input, Output> definePrompt<Input, Output>({
    required String name,
    String? policy,
    String? pin,
    String? variant,
    String? description,
    SchemanticType<Input>? inputSchema,
    String? system,
    List<Part>? systemParts,
    String? prompt,
    List<Part>? promptParts,
    List<Message>? messages,
    String? messagesTemplate,
    SchemanticType<Output>? outputSchema,
    GenerateActionOutputConfig? output,
    int? maxTurns,
    bool? returnToolRequests,
    Map<String, dynamic>? metadata,
    List<Tool>? tools,
    List<String>? toolNames,
    ToolChoice? toolChoice,
    List<GenerateMiddlewareRef>? use,
  }) => routedPrompt(
    _ai.definePrompt<Input, Output, Object?>(
      name: name,
      variant: variant,
      description: description,
      inputSchema: inputSchema,
      system: system,
      systemParts: systemParts,
      prompt: prompt,
      promptParts: promptParts,
      messages: messages,
      messagesTemplate: messagesTemplate,
      outputSchema: outputSchema,
      output: output,
      maxTurns: maxTurns,
      returnToolRequests: returnToolRequests,
      metadata: metadata,
      tools: tools,
      toolNames: toolNames,
      toolChoice: toolChoice,
      use: [
        call(policy: policy, pin: pin),
        ...?use,
      ],
    ),
  );

  /// The proxy of cloud target [key] in the app's Genkit: serves a request
  /// only inside this router's decision for [key].
  Future<ModelResponse> _serveProxy(
    String key,
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
  ) async {
    final target = targets[key]!;
    final decision = _currentDecision();
    if (decision == null ||
        !identical(decision.middleware.router, this) ||
        decision.target != key) {
      throw HybridRoutingException(
        'Cloud model "${target.model.name}" reached without the hybrid '
        'router "$name" choosing it.',
        status: StatusCode.permissionDenied,
      );
    }
    final lookup = _cloudLookups.then(
      (_) =>
          _cloudAi.registry.lookupAction(ActionType.model, target.model.name),
    );
    _cloudLookups = lookup.then((_) {}, onError: (Object _) {});
    // A lookup may queue behind a slow one: a cancel ends the wait, and the
    // decision is checked again once it is over.
    final cloud = await _RouterMiddleware._untilCancelled(
      () => lookup,
      ctx.cancel,
    );
    if (!decision.active) {
      throw HybridRoutingException(
        'Cloud model "${target.model.name}" reached after the hybrid router '
        '"$name"\'s decision for it ended.',
        status: StatusCode.permissionDenied,
      );
    }
    if (cloud is! Model) {
      throw HybridRoutingException(
        'Cloud model "${target.model.name}" is not resolved by any of the '
        'router\'s cloudPlugins.',
        status: StatusCode.notFound,
      );
    }
    return cloud(
      request,
      onChunk: ctx.streamingRequested ? ctx.sendChunk : null,
      context: ctx.context,
      cancel: ctx.cancel,
    );
  }

  /// Fails closed unless the cloud target [key] is reachable only through
  /// this router: the app's Genkit must not resolve its model (its plugin
  /// given to the app too), and the proxy must still be this router's.
  Future<void> _checkCloudIsPrivate(String key) async {
    final model = targets[key]!.model.name;
    Object? appModel;
    Object? proxy;
    try {
      appModel = await _ai.registry.lookupAction(ActionType.model, model);
      proxy = await _ai.registry.lookupAction(
        ActionType.model,
        _proxyName(key),
      );
    } catch (e) {
      throw HybridRoutingException(
        'Could not check that cloud model "$model" is private to the router: '
        '$e',
        status: StatusCode.failedPrecondition,
        cause: e,
      );
    }
    if (appModel != null) {
      throw HybridRoutingException(
        'The app\'s Genkit also resolves cloud model "$model": its plugin '
        'must be given only to the router\'s cloudPlugins.',
        status: StatusCode.failedPrecondition,
      );
    }
    if (!identical(proxy, _proxies[key])) {
      throw HybridRoutingException(
        'The proxy "${_proxyName(key)}" was replaced in the app\'s Genkit.',
        status: StatusCode.failedPrecondition,
      );
    }
  }

  /// The target a resume with no usable stamp goes to: only the device.
  String? get _safeTarget => targets.containsKey(kOnDevice) ? kOnDevice : null;
}

/// The generate middleware of one routed call (Genkit creates one per ref
/// per call, and reuses it for every turn and a restart's re-entry).
final class _RouterMiddleware extends GenerateMiddleware {
  _RouterMiddleware(this.router, this._config, this._ai);
  final HybridRouter router;
  final Map<String, dynamic>? _config;
  final GenkitAI _ai;

  /// The call's policy and pin, read from the ref's config by
  /// [_readConfig] at the first turn, again when an app middleware before
  /// the router runs the call once more.
  late String policyName;
  String? pin;

  /// A tool of this call ran (a restarted one included).
  bool _toolRan = false;

  /// A chunk of this call reached the caller.
  bool _chunkSent = false;

  /// Sends the chunks the running attempt holds for a cascade verdict and
  /// stops holding; null when no attempt runs.
  void Function()? _release;

  RoutePolicy get _policy => router.policies[policyName]!;

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> ctx,
    Future<ToolResult> Function(
      ToolRequestPart request,
      ActionFnArg<void, dynamic, void> ctx,
    )
    next,
  ) {
    _toolRan = true;
    // The cascade no longer applies: what was held is the answer's.
    _release?.call();
    // A tool runs outside the decision and the call: a sub-agent that calls
    // the router is routed on its own, its refusals are not this call's, and
    // a tool cannot reach a proxy on this decision.
    return outsideRoutedCalls(
      () =>
          runZoned(() => next(request, ctx), zoneValues: {_decisionKey: null}),
    );
  }

  @override
  Future<GenerateResult> generate(
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResult> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
  ) async {
    final current = _currentDecision();
    // Later turns, and a restart re-running the chain from inside `next`.
    if (current != null && identical(current.middleware, this)) {
      return next(envelope, ctx);
    }
    if (current != null) {
      throw HybridRoutingException(
        'A second hybrid router in the chain of one generate call.',
        status: StatusCode.failedPrecondition,
      );
    }
    if (envelope.currentTurn != 0) {
      throw HybridRoutingException(
        'Router "${router.name}" did not see the first turn of this call: '
        'put it first in `use:`.',
        status: StatusCode.failedPrecondition,
      );
    }
    _readConfig();
    if (envelope.request.config?.isNotEmpty ?? false) {
      throw HybridRoutingException(
        'A routed call takes no config: each target owns its own '
        '(HybridTarget.model.config).',
        status: StatusCode.invalidArgument,
      );
    }

    final clock = Stopwatch()..start();
    final routeRequest = RouteRequest(
      envelope.request,
      isStreaming: ctx.streamingRequested,
      context: ctx.context,
    );
    late _Decided decided;
    await _ai.run<Map<String, Object?>>('hybrid/route', () async {
      decided = await _decide(routeRequest, ctx.cancel, clock);
      return decided.info.toJson();
    });
    return _run(decided, routeRequest, envelope, ctx, next, clock);
  }

  /// Reads and checks [policyName] and [pin]. Here, not in the
  /// constructor: Genkit creates middleware outside the code that turns a
  /// throw into a `failed` result.
  void _readConfig() {
    final policy = _config?['policy'] ?? router.defaultPolicy;
    final pin = _config?['pin'];
    if (policy is! String || !router.policies.containsKey(policy)) {
      throw HybridRoutingException(
        'Router "${router.name}" has no policy "$policy".',
        status: StatusCode.invalidArgument,
      );
    }
    if (pin != null && (pin is! String || !router.targets.containsKey(pin))) {
      throw HybridRoutingException(
        'Router "${router.name}" has no target "$pin" to pin to.',
        status: StatusCode.invalidArgument,
      );
    }
    policyName = policy;
    this.pin = pin as String?;
  }

  Future<_Decided> _decide(
    RouteRequest request,
    CancellationToken? cancel,
    Stopwatch clock,
  ) async {
    final policy = _policy;
    RouteInfo info(
      String target,
      RouteSource source, {
      String? rule,
      String? reason,
      LabelVerdict? label,
      AbstainVerdict? abstain,
      Map<String, Object?> details = const {},
    }) => RouteInfo(
      router: router.name,
      policy: policyName,
      target: target,
      model: router.targets[target]!.model.name,
      source: source,
      routeTime: clock.elapsed,
      rule: rule,
      classifier:
          source == RouteSource.classifier ||
              source == RouteSource.abstain ||
              source == RouteSource.unavailable
          ? policy.classifier?.name
          : null,
      label: label?.label,
      score: label?.score,
      margin: label?.margin,
      abstainReason: abstain?.reason,
      reason: reason,
      details: details,
    );

    if (pin case final pin?) {
      return _Decided(RouteDecision.only(pin), info(pin, RouteSource.pin));
    }
    if (request.request.resume != null) {
      final stamped = _stampedTarget(request.request.messages);
      final target = stamped ?? router._safeTarget;
      if (target == null) {
        throw HybridRoutingException(
          'A resume without the router\'s stamp, and no "$kOnDevice" target '
          'to send it to.',
          status: StatusCode.failedPrecondition,
        );
      }
      return _Decided(
        RouteDecision.only(target),
        info(
          target,
          RouteSource.resume,
          reason: stamped == null ? 'no stamp' : null,
        ),
      );
    }
    for (final rule in policy.rules) {
      final decision = rule.decide(request);
      if (decision == null) continue;
      _checkTarget(decision.target, 'rule "${rule.name}"');
      return _Decided(
        decision,
        info(
          decision.target,
          RouteSource.rule,
          rule: rule.name,
          reason: decision.reason,
        ),
      );
    }
    final classifier = policy.classifier;
    if (classifier == null) {
      throw HybridRoutingException(
        'Policy "$policyName" decided nothing: no rule matched and it has no '
        'classifier.',
        status: StatusCode.failedPrecondition,
      );
    }
    final RouteVerdict verdict;
    try {
      verdict = await classifier.classify(request, cancel: cancel);
    } on RouteClassifierUnavailableException catch (e) {
      final decision = policy.onUnavailable;
      if (decision == null) {
        throw HybridRoutingException(
          'Classifier "${classifier.name}" is unavailable (${e.message}) and '
          'policy "$policyName" has no onUnavailable.',
          status: StatusCode.unavailable,
          cause: e,
        );
      }
      return _Decided(
        decision,
        info(
          decision.target,
          RouteSource.unavailable,
          // Why it is unavailable stays visible: a decider that closed for
          // good looks the same to the policy as one still loading.
          reason: decision.reason == null
              ? e.message
              : '${decision.reason} (${e.message})',
        ),
      );
    } catch (e) {
      // A cancel is Genkit's to report as `aborted`.
      if (cancel?.isCancelled ?? false) rethrow;
      throw HybridRoutingException(
        'Classifier "${classifier.name}" failed: $e',
        status: switch (e) {
          GenkitException(:final status) => status,
          // An index out of range is the classifier's bug.
          RangeError() => StatusCode.internal,
          // The request's text, which the user typed, is what it rejected.
          ArgumentError() => StatusCode.invalidArgument,
          _ => StatusCode.internal,
        },
        cause: e,
      );
    }
    // Checked and copied before anything reads it: the route info and the
    // trace are JSON, and a classifier may reuse its details map.
    final Map<String, Object?> details;
    try {
      if (verdict case LabelVerdict(
        :final score,
        :final margin,
      ) when !(score?.isFinite ?? true) || !(margin?.isFinite ?? true)) {
        throw ArgumentError('score $score, margin $margin: not finite');
      }
      details = Map.unmodifiable(
        jsonDecode(jsonEncode(verdict.details)) as Map<String, Object?>,
      );
    } catch (e) {
      throw HybridRoutingException(
        'Classifier "${classifier.name}" answered a verdict the route info '
        'cannot hold: $e',
        status: StatusCode.internal,
        cause: e,
      );
    }
    switch (verdict) {
      case final LabelVerdict verdict:
        final decision = policy.labels[verdict.label];
        if (decision == null) {
          throw HybridRoutingException(
            'Classifier "${classifier.name}" answered "${verdict.label}", '
            'which policy "$policyName" maps to no target.',
            // The classifier and the policy disagree, not the request.
            status: StatusCode.failedPrecondition,
          );
        }
        return _Decided(
          decision,
          info(
            decision.target,
            RouteSource.classifier,
            label: verdict,
            details: details,
            reason: decision.reason,
          ),
        );
      case final AbstainVerdict verdict:
        final decision =
            policy.onAbstain ?? const RouteDecision.only(kOnDevice);
        return _Decided(
          decision,
          info(
            decision.target,
            RouteSource.abstain,
            abstain: verdict,
            details: details,
            reason: decision.reason,
          ),
        );
    }
  }

  /// The target this router stamped on the message a resume answers: the
  /// last message only, as Genkit's own resume reads it, and only this
  /// router's stamp naming one of its targets.
  String? _stampedTarget(List<Message> messages) {
    final last = messages.lastOrNull;
    if (last == null || last.role != Role.model) return null;
    final stamp = last.metadata?[_stampKey];
    if (stamp is! Map) return null;
    final target = stamp['target'];
    if (stamp['router'] != router.name || target is! String) return null;
    return router.targets.containsKey(target) ? target : null;
  }

  void _checkTarget(String target, String where) {
    if (!router.targets.containsKey(target)) {
      throw HybridRoutingException(
        '$where named target "$target", which router "${router.name}" does '
        'not have.',
        status: StatusCode.invalidArgument,
      );
    }
  }

  /// Runs the decided target, then the fallback or cascade ones it allows.
  Future<GenerateResult> _run(
    _Decided decided,
    RouteRequest request,
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResult> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
    Stopwatch clock,
  ) async {
    final policy = _policy;
    var decision = decided.decision;
    var info = decided.info;
    final movable = !decision.isOnly && request.request.resume == null;
    final requires = request.requires;

    // The chosen target must be able to serve the request.
    if (!canServe(router.targets[decision.target]!, requires)) {
      final chosen = decision.target;
      String? capable;
      if (movable) {
        for (final t in policy.fallback) {
          if (t != chosen && canServe(router.targets[t]!, requires)) {
            capable = t;
            break;
          }
        }
      }
      if (capable == null) {
        final why = movable
            ? 'no fallback target can'
            : decision.isOnly
            ? 'the decision is only("$chosen"), which never moves (route '
                  'such requests with a rule or onAbstain)'
            : 'a resume stays on the target it was stamped with';
        throw HybridRoutingException(
          'Target "$chosen" cannot serve a request that needs '
          '${requires.map((c) => c.name).join(', ')}, and $why.',
          status: StatusCode.unimplemented,
          route: info,
        );
      }
      decision = RouteDecision.prefer(capable, reason: 'capability');
      info = info.copyWith(
        target: capable,
        model: router.targets[capable]!.model.name,
        reason: 'capability',
      );
    }

    final first = decision.target;
    final order = <String>[
      first,
      if (movable)
        for (final t in policy.fallback)
          if (t != first && canServe(router.targets[t]!, requires)) t,
    ];
    final attempts = <String>[];
    // The last attempt the loop moved on from (failed, or rejected by the
    // cascade), returned as it is when no later target runs.
    _Attempt? passed;
    // Why the loop moved on from it, and the failure that made it, if one.
    String? moveReason;
    Object? moveFailure;
    // The later targets it did not try, and why.
    final skipped = <String>[];
    for (var i = 0; i < order.length; i++) {
      var key = order[i];
      final isFirst = i == 0;
      if (moveFailure != null && !_mayMoveTo(key, moveFailure)) {
        skipped.add('$key not tried after ${_statusName(moveFailure)}');
        continue;
      }
      if (router.targets[key]!.isCloud) {
        final asked = isFirst
            ? info
            : info.copyWith(
                target: key,
                model: router.targets[key]!.model.name,
                reason: moveReason,
              );
        if (!await _askConsent(key, asked, ctx.cancel)) {
          if (!isFirst) {
            // Never move to the cloud without consent.
            skipped.add('$key refused by confirmCloud');
            continue;
          }
          if (decision.isOnly) {
            throw HybridRoutingException(
              'confirmCloud refused "$key", the only target this call may '
              'use.',
              status: StatusCode.permissionDenied,
              route: info,
            );
          }
          final onDevice = router.targets[kOnDevice];
          if (onDevice == null) {
            throw HybridRoutingException(
              'confirmCloud refused the cloud and there is no "$kOnDevice" '
              'target.',
              status: StatusCode.permissionDenied,
              route: info,
            );
          }
          if (!canServe(onDevice, requires)) {
            throw HybridRoutingException(
              'confirmCloud refused the cloud and "$kOnDevice" cannot serve '
              'this request.',
              status: StatusCode.unimplemented,
              route: info,
            );
          }
          key = kOnDevice;
          info = info.copyWith(
            target: kOnDevice,
            model: onDevice.model.name,
            source: RouteSource.consentRefused,
          );
          order.length = 1; // stays on the device
        } else {
          await router._checkCloudIsPrivate(key);
        }
      }
      if (attempts.isEmpty) info = info.copyWith(routeTime: clock.elapsed);
      attempts.add(key);
      info = info.copyWith(
        target: key,
        model: router.targets[key]!.model.name,
        attempts: List.unmodifiable(attempts),
        reason: moveReason,
      );

      final hasNext = i < order.length - 1;
      final cascade = policy.cascade;
      final holdChunks =
          cascade != null && hasNext && movable && ctx.streamingRequested;
      final held = <ModelResponseChunk>[];
      GenerateResult? result;
      Object? error;
      StackTrace? stack;
      try {
        result = await _attempt(
          key,
          envelope,
          ctx,
          next,
          held: holdChunks ? held : null,
        );
      } catch (e, s) {
        error = e;
        stack = s;
      }
      final failure =
          error ??
          (result!.finishReason == FinishReason.failed ? result.cause : null);
      final attempt = _Attempt(key, info, result, error, stack, held);
      if (failure != null) {
        // A cancelled call is Genkit's to report; after a tool ran or a
        // chunk was sent, the next target would repeat them.
        if (movable &&
            !_toolRan &&
            !_chunkSent &&
            !(ctx.cancel?.isCancelled ?? false) &&
            order.skip(i + 1).any((t) => _mayMoveTo(t, failure))) {
          passed = attempt;
          moveFailure = failure;
          moveReason = 'fallback: $key failed with ${_describe(failure)}';
          continue;
        }
        return _finish(attempt, ctx);
      }
      if (cascade != null && hasNext && movable && !_toolRan) {
        // The judge is app code: a refusal it meets is not this call's.
        final accepted = await _untilCancelled(
          () => outsideRoutedCalls(() => cascade(result!)),
          ctx.cancel,
        );
        if (!accepted) {
          passed = attempt;
          moveFailure = null;
          moveReason = 'cascade: $key rejected';
          continue;
        }
      }
      return _finish(attempt, ctx);
    }
    // Every later target was skipped (no consent for the cloud): the last
    // attempt that ran is the answer, and its route says what was not tried.
    final last = passed!;
    return _finish(
      last.withInfo(
        last.info.copyWith(reason: [?moveReason, ...skipped].join('; ')),
      ),
      ctx,
    );
  }

  /// Whether a call whose attempt failed with [failure] may move to [key]:
  /// on a transient failure, and to the cloud only on one Genkit reports as
  /// transient. INTERNAL and errors without a Genkit status are what a
  /// device bug or an over-long input raises on every request; they must not
  /// send every request to the cloud.
  bool _mayMoveTo(String key, Object failure) {
    if (!isTransient(failure)) return false;
    if (!router.targets[key]!.isCloud) return true;
    return failure is GenkitException &&
        _cloudMoveStatuses.contains(failure.status);
  }

  /// Ends the call with [attempt]: its error rethrown, or its result with
  /// its held chunks sent first.
  GenerateResult _finish(
    _Attempt attempt,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
  ) {
    if (attempt.error case final error?) {
      Error.throwWithStackTrace(error, attempt.stack!);
    }
    attempt.held.forEach(ctx.sendChunk);
    return _decorate(attempt.result!, attempt.info, attempt.key);
  }

  Future<bool> _askConsent(
    String key,
    RouteInfo info,
    CancellationToken? cancel,
  ) async {
    final confirm = router._confirmCloud;
    if (confirm == null) return true;
    try {
      return await _untilCancelled(
        // App code: a refusal it meets is not this call's.
        () => outsideRoutedCalls(
          () => confirm(
            CloudConsentRequest(
              target: key,
              model: router.targets[key]!.model.name,
              route: info,
            ),
          ),
        ),
        cancel,
      );
    } on CancelledException {
      rethrow;
    } catch (e) {
      throw HybridRoutingException(
        'confirmCloud failed: $e',
        status: StatusCode.internal,
        cause: e,
        route: info,
      );
    }
  }

  /// [body]'s value, unless [cancel] fires first: an app callback (a consent
  /// dialog, a cascade judge) must not keep a cancelled call waiting, nor
  /// turn it into a result.
  static Future<T> _untilCancelled<T>(
    FutureOr<T> Function() body,
    CancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();
    if (cancel == null) return body();
    final done = Completer<T>();
    final detach = cancel.onCancel(() {
      if (!done.isCompleted) {
        done.completeError(CancelledException(token: cancel));
      }
    });
    try {
      Future.sync(body).then(
        (v) {
          if (!done.isCompleted) done.complete(v);
        },
        onError: (Object e, StackTrace s) {
          if (!done.isCompleted) done.completeError(e, s);
        },
      );
      final value = await done.future;
      cancel.throwIfCancelled();
      return value;
    } finally {
      detach();
    }
  }

  /// One attempt on [key], inside this router's decision for it. The
  /// decision ends with the attempt; the caller's chunk callback runs
  /// outside it.
  Future<GenerateResult> _attempt(
    String key,
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResult> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next, {
    List<ModelResponseChunk>? held,
  }) async {
    final target = router.targets[key]!;
    final decision = _ZoneDecision(this, key);
    final outside = Zone.current;
    final routed = envelope.copyWith(
      request: GenerateActionOptions.fromJson({
        ...envelope.request.toJson(),
        'model': target.isCloud ? router._proxyName(key) : target.model.name,
        // A copy per request: a model may edit the config it is given.
        'config': switch (router._configJson[key]) {
          final json? => jsonDecode(json),
          null => null,
        },
      }),
    );
    void send(ModelResponseChunk chunk) {
      _chunkSent = true;
      // The caller's chunk callback is app code: outside the decision, and a
      // refusal it meets is not this call's.
      outside.run(() => outsideRoutedCalls(() => ctx.sendChunk(chunk)));
    }

    var holding = held;
    _release = () {
      final chunks = holding;
      holding = null;
      chunks?.forEach(send);
      chunks?.clear();
    };
    final routedCtx = ctx.copyWith(
      sendChunk: (chunk) {
        // A chunk sent after its attempt ended belongs to no answer.
        if (!decision.active) return;
        if (holding case final h?) {
          h.add(chunk);
        } else {
          send(chunk);
        }
      },
    );
    try {
      return await runZoned(
        () => next(routed, routedCtx),
        zoneValues: {_decisionKey: decision},
      );
    } finally {
      decision.active = false;
      _release = null;
    }
  }

  /// [result] with the route info on `custom` and, when it stopped on an
  /// interrupt, this router's stamp on the interrupted message.
  GenerateResult _decorate(GenerateResult result, RouteInfo info, String key) {
    // toJson() is the response's own map: a provider may hand the same
    // response out again.
    final json = {...result.modelResponse.toJson()};
    json['custom'] = {
      ...?(json['custom'] as Map?)?.cast<String, dynamic>(),
      kHybridRouteKey: info.toJson(),
    };
    final message = json['message'];
    if (result.finishReason == FinishReason.interrupted && message is Map) {
      json['message'] = {
        ...message.cast<String, dynamic>(),
        'metadata': {
          ...?(message['metadata'] as Map?)?.cast<String, dynamic>(),
          _stampKey: {'router': router.name, 'target': key},
        },
      };
    }
    return GenerateResult(
      ModelResponse.fromJson(json),
      request: result.modelRequest,
      output: result.output,
      cause: result.cause,
    );
  }
}

/// The failures that may move a call to a cloud target.
const _cloudMoveStatuses = {
  StatusCode.unavailable,
  StatusCode.deadlineExceeded,
  StatusCode.resourceExhausted,
  StatusCode.unimplemented,
};

/// [failure]'s Genkit status, or its type when it has none.
String _statusName(Object failure) => failure is GenkitException
    ? failure.status.wireName
    : '${failure.runtimeType}';

/// [failure] for a route reason: its Genkit status and message, or what it
/// prints, on one line and at most 200 characters.
String _describe(Object failure) {
  final text = failure is GenkitException
      ? '${failure.status.wireName}: ${failure.message}'
      : '$failure';
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length <= 200 ? line : '${line.substring(0, 197)}...';
}

final class _Attempt {
  const _Attempt(
    this.key,
    this.info,
    this.result,
    this.error,
    this.stack,
    this.held,
  );

  final String key;
  final RouteInfo info;
  final GenerateResult? result;
  final Object? error;
  final StackTrace? stack;

  /// Chunks held back for a cascade verdict.
  final List<ModelResponseChunk> held;

  /// This attempt with [info] as its route.
  _Attempt withInfo(RouteInfo info) =>
      _Attempt(key, info, result, error, stack, held);
}

final class _Decided {
  const _Decided(this.decision, this.info);

  final RouteDecision decision;
  final RouteInfo info;
}

/// [config] of target [key] as JSON text, as Genkit converts a call's
/// config (a Map, or an object whose toJson() returns one); null for none.
/// Throws [ArgumentError] when it cannot be sent.
String? _encodeConfig(String key, Object? config) {
  if (config == null) return null;
  final Object? map;
  try {
    map = config is Map ? config : (config as dynamic).toJson();
  } catch (e) {
    throw ArgumentError(
      'Target "$key": its config is not a Map and its toJson() failed: $e',
    );
  }
  if (map is! Map) {
    throw ArgumentError(
      'Target "$key": its config must be a Map or have a toJson() that '
      'returns one.',
    );
  }
  try {
    return jsonEncode(map);
  } catch (e) {
    throw ArgumentError('Target "$key": its config is not JSON: $e');
  }
}
