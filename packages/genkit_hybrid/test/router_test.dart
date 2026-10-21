import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:test/test.dart';

/// Calls and behaviour of the fake models, shared by a test.
class _World {
  int localCalls = 0;
  int cloudCalls = 0;
  int classifyCalls = 0;
  String nextLabel = 'easy';
  Object? cloudThrows;
  Object? localThrows;
  final log = <String>[];
}

ModelResponse _reply(ModelRequest req, String who) {
  if (req.messages.last.role == Role.tool) {
    return ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [TextPart(text: '$who answer')],
      ),
    );
  }
  if (req.tools?.isNotEmpty ?? false) {
    return ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [
          for (final tool in req.tools!)
            ToolRequestPart(
              toolRequest: ToolRequest(
                name: tool.name,
                ref: tool.name,
                input: {'q': 'x'},
              ),
            ),
        ],
      ),
    );
  }
  return ModelResponse(
    finishReason: FinishReason.stop,
    message: Message(
      role: Role.model,
      content: [TextPart(text: '$who plain')],
    ),
  );
}

/// A cloud plugin: resolves `fakecloud/<any>`.
class _CloudPlugin extends GenkitPlugin {
  _CloudPlugin(this.world);

  final _World world;

  @override
  String get name => 'fakecloud';

  @override
  Action? resolve(ActionType actionType, String name) {
    if (actionType != ActionType.model) return null;
    return Model(
      name: 'fakecloud/$name',
      fn: (req, ctx) async {
        world.cloudCalls++;
        world.log.add('cloud');
        if (world.cloudThrows case final e?) throw e;
        if (ctx.streamingRequested) {
          ctx.sendChunk(ModelResponseChunk(content: [TextPart(text: 'c1 ')]));
          ctx.sendChunk(ModelResponseChunk(content: [TextPart(text: 'c2')]));
        }
        return _reply(req, 'cloud');
      },
    );
  }
}

class _Classifier extends RouteClassifier {
  _Classifier(this.world, {this.throws});

  final _World world;
  final Object? throws;

  @override
  String get name => 'fake';

  @override
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  }) async {
    world.classifyCalls++;
    if (throws case final e?) throw e;
    if (world.nextLabel == '-') return const RouteVerdict.abstain('nothing');
    return RouteVerdict.label(world.nextLabel, score: 0.9, margin: 0.2);
  }
}

final cloudRef = modelRef('fakecloud/big');
final localRef = modelRef('local');

Genkit _app(_World world) {
  final ai = Genkit(isDevEnv: false, promptDir: null);
  ai.defineModel(
    name: 'local',
    fn: (req, ctx) async {
      world.localCalls++;
      world.log.add('local');
      if (world.localThrows case final e?) throw e;
      if (ctx.streamingRequested) {
        ctx.sendChunk(ModelResponseChunk(content: [TextPart(text: 'l1')]));
      }
      return _reply(req, 'local');
    },
  );
  ai.defineTool(
    name: 'lookup',
    description: 'Looks something up',
    inputSchema: .map(.string(), .dynamicSchema()),
    fn: (input, _) async => .response('found'),
  );
  ai.defineTool(
    name: 'confirm',
    description: 'Needs the user',
    inputSchema: .map(.string(), .dynamicSchema()),
    fn: (input, _) async => .interrupt('CONFIRM_ME'),
  );
  return ai;
}

HybridRouter _router(
  Genkit ai,
  _World world, {
  RoutePolicy? policy,
  Map<String, RoutePolicy>? policies,
  CloudConsent? confirmCloud,
  Map<String, HybridTarget>? targets,
  String name = 'hybrid-router',
}) => defineHybridRouter(
  ai,
  name: name,
  targets:
      targets ??
      {
        kOnDevice: HybridTarget.onDevice(localRef),
        kCloud: HybridTarget.cloud(cloudRef),
      },
  cloudPlugins: [_CloudPlugin(world)],
  policies:
      policies ??
      {
        'smart':
            policy ??
            RoutePolicy(
              classifier: _Classifier(world),
              labels: const {'easy': kOnDevice, 'hard': kCloud},
            ),
      },
  defaultPolicy: policies?.keys.first ?? 'smart',
  confirmCloud: confirmCloud,
);

void main() {
  late _World world;
  late Genkit ai;

  setUp(() {
    world = _World();
    ai = _app(world);
  });

  tearDown(() => ai.shutdown());

  group('one decision per call', () {
    test('a tool loop stays on the device', () async {
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.text, 'local answer');
      expect(world.classifyCalls, 1);
      expect(world.localCalls, 2);
      expect(world.cloudCalls, 0);
      expect(r.route!.source, RouteSource.classifier);
      expect(r.route!.label, 'easy');
      expect(r.route!.attempts, [kOnDevice]);
    });

    test('a tool loop stays in the cloud', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.text, 'cloud answer');
      expect(world.classifyCalls, 1);
      expect(world.cloudCalls, 2);
      expect(world.localCalls, 0);
      expect(r.route!.target, kCloud);
      expect(r.route!.model, 'fakecloud/big');
    });

    test('streaming goes through the proxy', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      final r = await stream.onResult;
      expect(chunks.join(), 'c1 c2');
      expect(r.text, 'cloud plain');
    });
  });

  group('fail closed', () {
    test('a call without the router names no model and fails', () async {
      _router(ai, world);
      final r = await ai.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(world.cloudCalls + world.localCalls, 0);
    });

    test('the proxy refuses a direct call', () async {
      _router(ai, world);
      final r = await ai.generate(
        model: modelRef('hybrid-router/$kCloud'),
        prompt: 'hi',
      );
      expect(r.finishReason, FinishReason.failed);
      expect(r.finishMessage, contains('without the hybrid router'));
      expect(world.cloudCalls, 0);
    });

    test('an inner middleware cannot move a device decision to the '
        'cloud', () async {
      final router = _router(ai, world);
      ai.defineGenerateMiddleware<Object?>(
        name: 'to-cloud',
        create: (_, _) => _SwitchModel('hybrid-router/$kCloud'),
      );
      await expectLater(
        router.generate(
          prompt: 'hi',
          use: [middlewareRef(name: 'to-cloud')],
        ),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.permissionDenied,
          ),
        ),
      );
      expect(world.cloudCalls, 0);
    });

    test('a second ref of the router is refused', () async {
      final router = _router(ai, world);
      await expectLater(
        router.generate(prompt: 'hi', use: [router()]),
        throwsA(isA<HybridRoutingException>()),
      );
      expect(world.classifyCalls, 1);
    });

    test('a default model is refused at definition', () {
      final withDefault = Genkit(
        isDevEnv: false,
        promptDir: null,
        model: localRef,
      );
      expect(() => _router(withDefault, world), throwsArgumentError);
    });

    test('a cloud plugin also given to the app is refused', () async {
      final leaky = Genkit(
        isDevEnv: false,
        promptDir: null,
        plugins: [_CloudPlugin(world)],
      );
      leaky.defineModel(name: 'local', fn: (r, _) async => _reply(r, 'l'));
      world.nextLabel = 'hard';
      final router = _router(leaky, world);
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.failedPrecondition,
          ),
        ),
      );
      expect(world.cloudCalls, 0);
    });

    test('a caller config is refused', () async {
      final router = _router(ai, world);
      final r = await ai.generate(
        prompt: 'hi',
        config: {'temperature': 0.1},
        use: [router()],
      );
      expect(r.finishReason, FinishReason.failed);
      expect(r.finishMessage, contains('no config'));
    });
  });

  group('decisions', () {
    test('rules run first, in order; the classifier is not asked', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          rules: [
            RouteRule.offline(isOnline: () => false),
            RouteRule.custom('never', (_) => const RouteDecision.only(kCloud)),
          ],
          classifier: _Classifier(world),
          labels: const {'easy': kOnDevice, 'hard': kCloud},
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.rule);
      expect(r.route!.rule, 'offline');
      expect(world.classifyCalls, 0);
    });

    test('a pin skips rules and classifier', () async {
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi', pin: kCloud);
      expect(r.text, 'cloud plain');
      expect(r.route!.source, RouteSource.pin);
      expect(world.classifyCalls, 0);
    });

    test('an abstain goes on the device by default', () async {
      world.nextLabel = '-';
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.abstain);
      expect(r.route!.abstainReason, 'nothing');
    });

    test('an unknown label fails the call', () async {
      world.nextLabel = 'weird';
      final router = _router(ai, world);
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(isA<HybridRoutingException>()),
      );
    });

    test(
      'an unavailable classifier fails the call without onUnavailable',
      () async {
        final router = _router(
          ai,
          world,
          policy: RoutePolicy(
            classifier: _Classifier(
              world,
              throws: const RouteClassifierUnavailableException('loading'),
            ),
            labels: const {'easy': kOnDevice},
          ),
        );
        await expectLater(
          router.generate(prompt: 'hi'),
          throwsA(
            isA<HybridRoutingException>().having(
              (e) => e.status,
              'status',
              StatusCode.unavailable,
            ),
          ),
        );
        expect(world.localCalls + world.cloudCalls, 0);
      },
    );

    test('onUnavailable decides while the classifier is unavailable', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(
            world,
            throws: const RouteClassifierUnavailableException('loading'),
          ),
          labels: const {'easy': kOnDevice},
          onUnavailable: kOnDevice,
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.unavailable);
    });

    test('a classifier error fails the call and is never an abstain', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world, throws: StateError('broken')),
          labels: const {'easy': kOnDevice},
        ),
      );
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
      expect(world.localCalls, 0);
    });

    test('a target without the capability moves to a capable '
        'fallback', () async {
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(localRef, supports: const {}),
          kCloud: HybridTarget.cloud(
            cloudRef,
            supports: const {ModelCapability.tools},
          ),
        },
        policy: RoutePolicy(
          rules: [
            RouteRule.custom(
              'dev',
              (_) => const RouteDecision.prefer(kOnDevice),
            ),
          ],
          fallback: const [kCloud],
        ),
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.finishMessage, isNull);
      expect(r.text, 'cloud answer');
      expect(r.route!.reason, 'capability');
      expect(world.localCalls, 0);
    });
  });

  group('fallback and cascade', () {
    test('a transient failure before any output falls back', () async {
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'cloud plain');
      expect(r.route!.attempts, [kOnDevice, kCloud]);
    });

    test('no fallback once a tool ran', () async {
      var calls = 0;
      ai.defineTool(
        name: 'second',
        description: 'fails',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async => throw StateError('tool broke'),
      );
      ai.defineTool(
        name: 'first',
        description: 'counts',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          calls++;
          return .response('ok');
        },
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
      );
      final r = await router.generate(
        prompt: 'hi',
        toolNames: ['first', 'second'],
      );
      expect(r.finishReason, FinishReason.failed);
      // A fallback would have re-run the loop in the cloud, tools included.
      expect(world.cloudCalls, 0);
      expect(calls, lessThanOrEqualTo(1));
    });

    test('an only decision never falls back', () async {
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('dev', (_) => const RouteDecision.only(kOnDevice)),
          ],
          fallback: const [kCloud],
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(world.cloudCalls, 0);
    });

    test('a rejected result escalates; held chunks are dropped', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (result) => result.text.startsWith('cloud'),
        ).withRule(kOnDevice),
      );
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      final r = await stream.onResult;
      expect(r.text, 'cloud plain');
      expect(chunks.join(), 'c1 c2', reason: 'no on-device chunk leaked');
      expect(r.route!.attempts, [kOnDevice, kCloud]);
    });

    test('an accepted result flushes its held chunks', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (_) => true,
        ).withRule(kOnDevice),
      );
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      expect(chunks.join(), 'l1');
      expect(world.cloudCalls, 0);
    });
  });

  group('consent', () {
    test('a fallback refused the cloud reports the original failure', () async {
      world.localThrows = GenkitException(
        'device busy',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
        confirmCloud: (_) => false,
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(r.finishMessage, contains('device busy'));
      expect(world.cloudCalls, 0);
    });

    test('a rejected cascade refused the cloud keeps the device answer and '
        'its chunks', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (_) => false,
        ).withRule(kOnDevice),
        confirmCloud: (_) => false,
      );
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      final r = await stream.onResult;
      expect(r.text, 'local plain');
      expect(chunks.join(), 'l1');
      expect(world.cloudCalls, 0);
    });

    test('a refusal keeps the call on the device, asked once', () async {
      world.nextLabel = 'hard';
      var asked = 0;
      final router = _router(
        ai,
        world,
        confirmCloud: (_) {
          asked++;
          return false;
        },
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.consentRefused);
      expect(asked, 1);
      expect(world.cloudCalls, 0);
    });

    test('a refusal with no device target fails', () async {
      final router = _router(
        ai,
        world,
        targets: {kCloud: HybridTarget.cloud(cloudRef)},
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('c', (_) => const RouteDecision.prefer(kCloud)),
          ],
        ),
        confirmCloud: (_) => false,
      );
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.permissionDenied,
          ),
        ),
      );
    });
  });

  group('resume', () {
    test('keeps the stamped decision', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final r1 = await router.generate(
        prompt: 'please confirm',
        toolNames: ['confirm'],
      );
      expect(r1.finishReason, FinishReason.interrupted);
      world.nextLabel = 'easy';
      final r2 = await router.generate(
        messages: r1.messages,
        toolNames: ['confirm'],
        interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
      );
      expect(r2.text, 'cloud answer');
      expect(r2.route!.source, RouteSource.resume);
      expect(world.classifyCalls, 1);
      expect(world.localCalls, 0);
    });

    test('without a stamp goes on the device', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final r1 = await router.generate(
        prompt: 'please confirm',
        toolNames: ['confirm'],
      );
      final unstamped = [
        ...r1.messages.take(r1.messages.length - 1),
        Message.fromJson({
          ...r1.messages.last.toJson(),
          'metadata': <String, dynamic>{},
        }),
      ];
      final r2 = await router.generate(
        messages: unstamped,
        toolNames: ['confirm'],
        interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
      );
      expect(r2.text, 'local answer');
      expect(r2.route!.reason, 'no stamp');
    });

    test('a stamp in the history does not pin a fresh turn', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final r1 = await router.generate(
        prompt: 'please confirm',
        toolNames: ['confirm'],
      );
      final r2 = await router.generate(
        messages: r1.messages,
        toolNames: ['confirm'],
        interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
      );
      world.nextLabel = 'easy';
      final r3 = await router.generate(
        messages: [
          ...r2.messages,
          Message(
            role: Role.user,
            content: [TextPart(text: 'again')],
          ),
        ],
      );
      expect(r3.text, 'local plain');
      expect(r3.route!.source, RouteSource.classifier);
    });

    test('a restarted tool re-enters the same router', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world);
      final r1 = await router.generate(
        prompt: 'please confirm',
        toolNames: ['confirm'],
      );
      final r2 = await router.generate(
        messages: r1.messages,
        toolNames: ['confirm'],
        interruptRestart: [r1.interrupts.first],
      );
      expect(r2.finishReason, FinishReason.interrupted);
      expect(world.localCalls, 0);
    });
  });

  group('nesting', () {
    test('a tool that calls the router is routed on its own', () async {
      final router = _router(ai, world);
      ai.defineTool(
        name: 'subagent',
        description: 'asks the router',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          final inner = await router.generate(prompt: 'inner', pin: kCloud);
          return .response(inner.text);
        },
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['subagent']);
      expect(r.text, 'local answer');
      expect(world.cloudCalls, 1);
    });
  });

  group('prompts', () {
    test('a routed prompt is routed and throws a refusal', () async {
      final router = _router(ai, world);
      final p = router.definePrompt<Object?, Object?>(
        name: 'greet',
        prompt: 'hello',
        pin: kCloud,
      );
      final r = await p.call(null);
      expect(r.text, 'cloud plain');

      final bad = router.definePrompt<Object?, Object?>(
        name: 'bad',
        prompt: 'hello',
        use: [router()],
      );
      await expectLater(bad.call(null), throwsA(isA<HybridRoutingException>()));
    });
  });

  group('definition', () {
    test('rejects unknown targets and missing abstain targets', () {
      expect(
        () => _router(
          ai,
          world,
          policy: const RoutePolicy(fallback: ['nowhere']),
        ),
        throwsArgumentError,
      );
      expect(
        () => _router(
          ai,
          world,
          targets: {kCloud: HybridTarget.cloud(cloudRef)},
          policy: RoutePolicy(
            classifier: _Classifier(world),
            labels: const {'hard': kCloud},
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a taken name', () {
      _router(ai, world);
      expect(() => _router(ai, world), throwsArgumentError);
    });

    test('call() rejects unknown policy and pin names', () {
      final router = _router(ai, world);
      expect(() => router(policy: 'nope'), throwsArgumentError);
      expect(() => router(pin: 'nope'), throwsArgumentError);
    });
  });
}

extension on RoutePolicy {
  /// This policy with a first rule preferring [target].
  RoutePolicy withRule(String target) => RoutePolicy(
    rules: [
      RouteRule.custom('test', (_) => RouteDecision.prefer(target)),
      ...rules,
    ],
    classifier: classifier,
    labels: labels,
    onAbstain: onAbstain,
    onUnavailable: onUnavailable,
    fallback: fallback,
    cascade: cascade,
  );
}

/// An app middleware that switches the model, as a model-level fallback
/// would.
class _SwitchModel extends GenerateMiddleware {
  _SwitchModel(this.targetModel);

  final String targetModel;

  @override
  Future<GenerateResult> generate(
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResult> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
  ) => next(
    envelope.copyWith(
      request: GenerateActionOptions.fromJson({
        ...envelope.request.toJson(),
        'model': targetModel,
      }),
    ),
    ctx,
  );
}
