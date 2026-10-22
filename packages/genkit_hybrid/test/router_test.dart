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

  /// When set, the first streamed cloud call waits for it after its first
  /// chunk.
  Completer<void>? cloudGate;

  /// When set, every cloud call returns this same object, as a plugin cache
  /// would.
  ModelResponse? cloudResponse;

  /// When set, a streamed cloud call throws it after its first chunk.
  Object? cloudThrowsAfterChunk;

  /// How often the cloud plugin was initialised.
  int cloudInits = 0;

  /// When set, the cloud plugin's initialisation waits for it.
  Completer<void>? cloudInitGate;

  /// When set, a cloud call that answers a tool's output throws it.
  Object? cloudThrowsAfterTool;

  /// When true, a cloud call schedules a chunk for after it returned, and
  /// the device answers only once that chunk was sent.
  bool cloudLateChunk = false;
  final lateChunkSent = Completer<void>();
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
  Future<List<Action>> init() async {
    world.cloudInits++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (world.cloudInitGate case final gate?) await gate.future;
    return const [];
  }

  @override
  Action? resolve(ActionType actionType, String name) {
    if (actionType != ActionType.model) return null;
    return Model(
      name: 'fakecloud/$name',
      fn: (req, ctx) async {
        world.cloudCalls++;
        world.log.add('cloud');
        if (world.cloudLateChunk) {
          Timer.run(() {
            ctx.sendChunk(
              ModelResponseChunk(content: [TextPart(text: 'late')]),
            );
            world.lateChunkSent.complete();
          });
        }
        if (world.cloudThrowsAfterTool case final e?
            when req.messages.last.role == Role.tool) {
          throw e;
        }
        if (world.cloudThrows case final e?) throw e;
        if (ctx.streamingRequested) {
          ctx.sendChunk(ModelResponseChunk(content: [TextPart(text: 'c1 ')]));
          if (world.cloudThrowsAfterChunk case final e?) throw e;
          if (world.cloudGate case final gate? when world.cloudCalls == 1) {
            await gate.future;
          }
          ctx.sendChunk(ModelResponseChunk(content: [TextPart(text: 'c2')]));
        }
        return world.cloudResponse ?? _reply(req, 'cloud');
      },
    );
  }
}

final class _Classifier extends RouteClassifier {
  _Classifier(this.world, {this.throws, this.verdict});

  final _World world;
  final Object? throws;

  /// Answered instead of the world's label, when set.
  final RouteVerdict Function()? verdict;

  @override
  String get name => 'fake';

  @override
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  }) async {
    world.classifyCalls++;
    if (throws case final e?) throw e;
    if (verdict case final v?) return v();
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
      if (world.cloudLateChunk) await world.lateChunkSent.future;
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
              labels: const {
                'easy': RouteDecision.prefer(kOnDevice),
                'hard': RouteDecision.prefer(kCloud),
              },
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

    test('concurrent first cloud calls initialise the cloud plugin '
        'once', () async {
      final router = _router(ai, world);
      final results = await Future.wait([
        router.generate(prompt: 'a', pin: kCloud),
        router.generate(prompt: 'b', pin: kCloud),
      ]);
      expect(results.map((r) => r.text), ['cloud plain', 'cloud plain']);
      expect(world.cloudInits, 1);
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
      // Nor does the app's Genkit resolve the cloud model itself.
      final direct = await ai.generate(model: cloudRef, prompt: 'hi');
      expect(direct.finishReason, FinishReason.failed);
      expect(world.cloudCalls + world.localCalls, 0);
    });

    test('a proxy refuses another router\'s decision', () async {
      final a = _router(ai, world, name: 'a');
      _router(ai, world, name: 'b');
      ai.defineGenerateMiddleware<Object?>(
        name: 'to-b',
        create: (_, _) => _SwitchModel('b/$kCloud'),
      );
      await expectLater(
        a.generate(
          prompt: 'hi',
          pin: kCloud,
          use: [middlewareRef(name: 'to-b')],
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

    test('a replaced proxy is refused', () async {
      final router = _router(ai, world);
      var replaced = 0;
      ai.defineModel(
        name: 'hybrid-router/$kCloud',
        fn: (req, _) async {
          replaced++;
          return _reply(req, 'impostor');
        },
      );
      await expectLater(
        router.generate(prompt: 'hi', pin: kCloud),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.failedPrecondition,
          ),
        ),
      );
      expect(replaced + world.cloudCalls, 0);
    });

    test('a refusal fails the chunk stream and the result', () async {
      final router = _router(
        ai,
        world,
        policies: {'none': const RoutePolicy()},
      );
      final stream = router.generateStream(prompt: 'hi');
      await expectLater(
        stream.toList(),
        throwsA(isA<HybridRoutingException>()),
      );
      await expectLater(
        stream.onResult,
        throwsA(isA<HybridRoutingException>()),
      );
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

    test('a zone captured in a cloud call cannot reach the cloud '
        'afterwards', () async {
      final router = _router(ai, world);
      ai.defineGenerateMiddleware<Object?>(
        name: 'capture',
        create: (_, _) => _CaptureZone(),
      );
      await router.generate(
        prompt: 'hi',
        pin: kCloud,
        use: [middlewareRef(name: 'capture')],
      );
      expect(world.cloudCalls, 1);
      final replay = await _CaptureZone.captured!.run(
        () => ai.generate(
          model: modelRef('hybrid-router/$kCloud'),
          prompt: 'replay',
        ),
      );
      expect(replay.finishReason, FinishReason.failed);
      expect(replay.finishMessage, contains('without the hybrid router'));
      expect(world.cloudCalls, 1);
    });

    test('onChunk runs outside the decision', () async {
      final router = _router(ai, world);
      world.cloudGate = Completer<void>();
      Future<GenerateResult>? sneak;
      final r = await router.generate(
        prompt: 'hi',
        pin: kCloud,
        onChunk: (_) {
          sneak ??= ai
              .generate(
                model: modelRef('hybrid-router/$kCloud'),
                prompt: 'sneak',
              )
              .whenComplete(world.cloudGate!.complete);
        },
      );
      expect(r.text, 'cloud plain');
      final s = await sneak!;
      expect(s.finishReason, FinishReason.failed);
      expect(world.cloudCalls, 1);
    });

    test('a proxy call still waiting for its lookup when its attempt ends '
        'is refused', () async {
      final router = _router(ai, world);
      world.cloudInitGate = Completer<void>();
      Future<GenerateResult>? sneak;
      ai.defineGenerateMiddleware<Object?>(
        name: 'rogue',
        create: (_, _) => _Rogue(() async {
          sneak ??= ai.generate(
            model: modelRef('hybrid-router/$kCloud'),
            prompt: 'sneak',
          );
          // Answer only once the sneaked call passed the proxy's check and
          // waits for the lookup.
          while (world.cloudInits == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }),
      );
      final r = await router.generate(
        prompt: 'hi',
        pin: kCloud,
        use: [middlewareRef(name: 'rogue')],
      );
      expect(r.text, 'rogue');
      // The attempt has ended; the sneaked call still waits for the lookup.
      world.cloudInitGate!.complete();
      final s = await sneak!;
      expect(s.finishReason, FinishReason.failed);
      expect(s.finishMessage, contains('decision for it ended'));
      expect(world.cloudCalls, 0);
    });

    test('a cancel while the cloud lookup waits aborts the call', () async {
      final router = _router(ai, world);
      world.cloudInitGate = Completer<void>();
      final first = router.generate(prompt: 'a', pin: kCloud);
      final controller = CancellationController();
      final second = router.generate(
        prompt: 'b',
        pin: kCloud,
        cancel: controller.token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.cancel('stop');
      final r = await second.timeout(const Duration(seconds: 5));
      expect(r.finishReason, FinishReason.aborted);
      world.cloudInitGate!.complete();
      expect((await first).text, 'cloud plain');
      expect(world.cloudCalls, 1);
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

    test('a bad policy or pin in a plain call fails it, it does not '
        'throw', () async {
      _router(ai, world);
      for (final config in [
        {'policy': 'nope'},
        {'pin': 'nope'},
        {'pin': 3},
      ]) {
        final r = await ai.generate(
          prompt: 'hi',
          use: [middlewareRef(name: 'hybrid-router', config: config)],
        );
        expect(r.finishReason, FinishReason.failed, reason: '$config');
        expect(r.cause, isA<HybridRoutingException>(), reason: '$config');
      }
      expect(world.localCalls + world.cloudCalls, 0);
    });

    test('a later turn without the decision is refused', () async {
      final router = _router(ai, world);
      ai.defineGenerateMiddleware<Object?>(
        name: 'turn1',
        create: (_, _) => _LaterTurn(),
      );
      final r = await ai.generate(
        prompt: 'hi',
        use: [
          middlewareRef(name: 'turn1'),
          router(),
        ],
      );
      expect(r.finishReason, FinishReason.failed);
      expect(r.cause, isA<HybridRoutingException>());
      expect(world.localCalls + world.cloudCalls, 0);
    });

    test('an empty config is no config', () async {
      final router = _router(ai, world);
      final r = await ai.generate(
        prompt: 'hi',
        config: <String, dynamic>{},
        use: [router()],
      );
      expect(r.text, 'local plain');
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
          labels: const {
            'easy': RouteDecision.prefer(kOnDevice),
            'hard': RouteDecision.prefer(kCloud),
          },
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.rule);
      expect(r.route!.rule, 'offline');
      expect(world.classifyCalls, 0);
    });

    test('a pin skips rules and classifier', () async {
      var ruled = 0;
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('dev', (_) {
              ruled++;
              return const RouteDecision.only(kOnDevice);
            }),
          ],
          classifier: _Classifier(world),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
        ),
      );
      final r = await router.generate(prompt: 'hi', pin: kCloud);
      expect(r.text, 'cloud plain');
      expect(r.route!.source, RouteSource.pin);
      expect(ruled, 0);
      expect(world.classifyCalls, 0);
    });

    test('a rule naming an unknown target fails the call', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('x', (_) => const RouteDecision.only('nowhere')),
          ],
        ),
      );
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.invalidArgument,
          ),
        ),
      );
    });

    test('no capable target is refused', () async {
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(localRef, supports: const {}),
          kCloud: HybridTarget.cloud(cloudRef, supports: const {}),
        },
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
      );
      await expectLater(
        router.generate(prompt: 'hi', toolNames: ['lookup']),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.unimplemented,
          ),
        ),
      );
      expect(world.localCalls + world.cloudCalls, 0);
    });

    test('a cancel while classifying aborts the call with the classifier\'s '
        'own error', () async {
      final controller = CancellationController();
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(
            world,
            verdict: () {
              controller.cancel(); // no reason: Genkit reports the error
              throw StateError('interrupted');
            },
          ),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
        ),
      );
      final r = await router.generate(prompt: 'hi', cancel: controller.token);
      expect(r.finishReason, FinishReason.aborted);
      expect(r.cause, isA<StateError>());
      expect(world.localCalls, 0);
    });

    test('an abstain goes on the device by default', () async {
      world.nextLabel = '-';
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.abstain);
      expect(r.route!.abstainReason, 'nothing');
    });

    test('an unknown label fails the call as FAILED_PRECONDITION', () async {
      world.nextLabel = 'weird';
      final router = _router(ai, world);
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
    });

    test('an only decision on a target that cannot serve is refused, not '
        'moved', () async {
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
            RouteRule.custom('dev', (_) => const RouteDecision.only(kOnDevice)),
          ],
          fallback: const [kCloud],
        ),
      );
      await expectLater(
        router.generate(prompt: 'hi', toolNames: ['lookup']),
        throwsA(
          isA<HybridRoutingException>()
              .having((e) => e.status, 'status', StatusCode.unimplemented)
              .having((e) => e.message, 'message', contains('only')),
        ),
      );
      expect(world.localCalls + world.cloudCalls, 0);
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
            labels: const {'easy': RouteDecision.prefer(kOnDevice)},
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
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
          onUnavailable: const RouteDecision.prefer(kOnDevice),
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.unavailable);
      expect(r.route!.reason, 'loading');
    });

    test('onUnavailable\'s own reason keeps why the classifier is '
        'unavailable', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(
            world,
            throws: const RouteClassifierUnavailableException(
              'The decider was closed.',
            ),
          ),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
          onUnavailable: const RouteDecision.prefer(
            kOnDevice,
            reason: 'classifier not ready',
          ),
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.route!.reason, 'classifier not ready (The decider was closed.)');
    });

    test('a RangeError from the classifier is INTERNAL, a bug and not the '
        'user\'s input', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world, throws: RangeError('index 3')),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
        ),
      );
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.internal,
          ),
        ),
      );
    });

    test('an ArgumentError from the classifier is INVALID_ARGUMENT', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world, throws: ArgumentError('bad text')),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
        ),
      );
      await expectLater(
        router.generate(prompt: 'hi'),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.invalidArgument,
          ),
        ),
      );
    });

    for (final (name, verdict) in <(String, RouteVerdict Function())>[
      (
        'a NaN margin',
        () => const RouteVerdict.label('easy', margin: double.nan),
      ),
      (
        'an infinite score',
        () => const RouteVerdict.label('easy', score: double.infinity),
      ),
      (
        'details that are not JSON',
        () => RouteVerdict.abstain('x', details: {'at': DateTime(2026)}),
      ),
    ]) {
      test('a verdict with $name fails the call', () async {
        final router = _router(
          ai,
          world,
          policy: RoutePolicy(
            classifier: _Classifier(world, verdict: verdict),
            labels: const {'easy': RouteDecision.prefer(kOnDevice)},
          ),
        );
        await expectLater(
          router.generate(prompt: 'hi'),
          throwsA(
            isA<HybridRoutingException>().having(
              (e) => e.message,
              'message',
              contains('Classifier "fake"'),
            ),
          ),
        );
        expect(world.localCalls, 0);
      });
    }

    test('the route keeps its own copy of the verdict details', () async {
      final details = <String, Object?>{'n': 1};
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(
            world,
            verdict: () => RouteVerdict.label('easy', details: details),
          ),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
        ),
      );
      final r = await router.generate(prompt: 'hi');
      details['n'] = 2;
      expect(r.route!.details, {'n': 1});
    });

    test('a classifier error fails the call and is never an abstain', () async {
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world, throws: StateError('broken')),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
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

    test('no fallback once a tool ran, when the next turn fails', () async {
      var calls = 0;
      ai.defineTool(
        name: 'count',
        description: 'counts',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          calls++;
          return .response('ok');
        },
      );
      world.cloudThrowsAfterTool = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kOnDevice]).withRule(kCloud),
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['count']);
      expect(r.finishReason, FinishReason.failed);
      // A fallback would re-run the loop on the device, the tool included.
      expect(world.localCalls, 0);
      expect(calls, 1);
    });

    test('a chunk an ended attempt sends later is dropped', () async {
      world.cloudLateChunk = true;
      world.cloudThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kOnDevice]).withRule(kCloud),
      );
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      final r = await stream.onResult;
      expect(r.text, 'local plain');
      expect(world.lateChunkSent.isCompleted, isTrue);
      expect(chunks.join(), 'l1');
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
      expect(r.route!.target, kCloud);
      expect(r.route!.model, 'fakecloud/big');
      expect(r.route!.reason, 'cascade: onDevice rejected');
    });

    test('no cascade once a tool ran', () async {
      var judged = 0;
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (_) {
            judged++;
            return false;
          },
        ).withRule(kOnDevice),
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.text, 'local answer');
      expect(world.cloudCalls, 0);
      expect(judged, 0);
    });

    test('the held chunks of a tool loop reach the caller when the tool '
        'runs', () async {
      final seenBeforeTool = <String>[];
      final streamed = <String>[];
      ai.defineTool(
        name: 'peek',
        description: 'records what the caller has seen',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          seenBeforeTool.addAll(streamed);
          return .response('ok');
        },
      );
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (_) => true,
        ).withRule(kOnDevice),
      );
      await router.generate(
        prompt: 'hi',
        toolNames: ['peek'],
        onChunk: (c) => streamed.add(c.text),
      );
      expect(seenBeforeTool, ['l1']);
      expect(streamed.where((t) => t.isNotEmpty), ['l1', 'l1']);
    });

    test('no fallback once a chunk was sent', () async {
      world.cloudThrowsAfterChunk = GenkitException(
        'cut',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kOnDevice]).withRule(kCloud),
      );
      final stream = router.generateStream(prompt: 'hi');
      final chunks = [await for (final c in stream) c.text];
      final r = await stream.onResult;
      expect(r.finishReason, FinishReason.failed);
      expect(chunks.join(), 'c1 ');
      expect(world.localCalls, 0);
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

  group('privacy of moves', () {
    test('a label mapped to only stays on the device when it fails', () async {
      world.localThrows = GenkitException(
        'busy',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world),
          labels: const {
            'easy': RouteDecision.only(kOnDevice),
            'hard': RouteDecision.prefer(kCloud),
          },
          fallback: const [kCloud],
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(world.cloudCalls, 0);
    });

    test('an abstain stays on the device by default', () async {
      world.nextLabel = '-';
      world.localThrows = GenkitException(
        'busy',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world),
          labels: const {'hard': RouteDecision.prefer(kCloud)},
          fallback: const [kCloud],
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(world.cloudCalls, 0);
    });

    test('an explicit onAbstain is used', () async {
      world.nextLabel = '-';
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          classifier: _Classifier(world),
          labels: const {'easy': RouteDecision.prefer(kOnDevice)},
          onAbstain: const RouteDecision.only(kCloud, reason: 'unsure'),
        ),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'cloud plain');
      expect(r.route!.source, RouteSource.abstain);
      expect(r.route!.reason, 'unsure');
    });

    for (final (name, error) in [
      ('INTERNAL', GenkitException('bug', status: StatusCode.internal)),
      ('a non-Genkit error', StateError('too long')),
    ]) {
      test('$name on the device does not move to the cloud', () async {
        world.localThrows = error;
        final router = _router(
          ai,
          world,
          policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
        );
        final r = await router.generate(prompt: 'hi');
        expect(r.finishReason, FinishReason.failed);
        expect(world.cloudCalls, 0);
      });
    }

    test('a non-Genkit cloud failure moves to the device, and says '
        'why', () async {
      world.cloudThrows = TimeoutException('no network');
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kOnDevice]).withRule(kCloud),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.target, kOnDevice);
      expect(r.route!.model, 'local');
      expect(r.route!.attempts, [kCloud, kOnDevice]);
      expect(
        r.route!.reason,
        'fallback: cloud failed with TimeoutException: no network',
      );
    });

    test('an INTERNAL cloud failure moves to the device: genkit_google_genai '
        'reports an offline network so', () async {
      world.cloudThrows = GenkitException(
        'SocketException: Failed host lookup',
        status: StatusCode.internal,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kOnDevice]).withRule(kCloud),
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.attempts, [kCloud, kOnDevice]);
      expect(
        r.route!.reason,
        'fallback: cloud failed with INTERNAL: SocketException: Failed host '
        'lookup',
      );
    });

    test('a transient device failure moves to the cloud and records the '
        'status', () async {
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
      expect(r.route!.target, kCloud);
      expect(r.route!.model, 'fakecloud/big');
      expect(
        r.route!.reason,
        'fallback: onDevice failed with UNAVAILABLE: down',
      );
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
      expect(
        r.route!.reason,
        'fallback: onDevice failed with UNAVAILABLE: device busy; cloud '
        'refused by confirmCloud',
      );
      expect(world.cloudCalls, 0);
    });

    test('the consent request of a fallback target describes that '
        'target', () async {
      world.localThrows = GenkitException(
        'device busy',
        status: StatusCode.unavailable,
      );
      CloudConsentRequest? asked;
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
        confirmCloud: (request) {
          asked = request;
          return true;
        },
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'cloud plain');
      expect(asked!.target, kCloud);
      expect(asked!.route.target, kCloud);
      expect(asked!.route.model, 'fakecloud/big');
      expect(asked!.route.attempts, [kOnDevice]);
      expect(asked!.route.reason, startsWith('fallback: onDevice failed'));
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
      expect(
        r.route!.reason,
        'cascade: onDevice rejected; cloud refused by confirmCloud',
      );
      expect(world.cloudCalls, 0);
    });

    test('a refusal keeps a prefer call on the device', () async {
      world.nextLabel = 'hard';
      final router = _router(ai, world, confirmCloud: (_) => false);
      final r = await router.generate(prompt: 'hi');
      expect(r.text, 'local plain');
      expect(r.route!.source, RouteSource.consentRefused);
      expect(r.route!.target, kOnDevice);
      expect(world.cloudCalls, 0);
    });

    test('is asked once per call, not per turn', () async {
      world.nextLabel = 'hard';
      var asked = 0;
      final router = _router(
        ai,
        world,
        confirmCloud: (_) {
          asked++;
          return true;
        },
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.text, 'cloud answer');
      expect(world.cloudCalls, 2);
      expect(asked, 1);
    });

    test('is asked for each cloud target', () async {
      world.cloudThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final asked = <String>[];
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(localRef),
          kCloud: HybridTarget.cloud(cloudRef),
          'other': HybridTarget.cloud(modelRef('fakecloud/other')),
        },
        policy: const RoutePolicy(fallback: ['other']).withRule(kCloud),
        confirmCloud: (request) {
          asked.add(request.target);
          return true;
        },
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(asked, [kCloud, 'other']);
    });

    test('a refusal that moved the call keeps it on the device', () async {
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final asked = <String>[];
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(localRef),
          kCloud: HybridTarget.cloud(cloudRef),
          'other': HybridTarget.cloud(modelRef('fakecloud/other')),
        },
        policy: const RoutePolicy(fallback: ['other']).withRule(kCloud),
        confirmCloud: (request) {
          asked.add(request.target);
          return false;
        },
      );
      final r = await router.generate(prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(asked, [kCloud]);
      expect(world.cloudCalls, 0);
    });

    for (final (name, pin, policy) in [
      ('a pin to the cloud', kCloud, null),
      (
        'an only decision for the cloud',
        null,
        RoutePolicy(
          rules: [
            RouteRule.custom('c', (_) => const RouteDecision.only(kCloud)),
          ],
        ),
      ),
    ]) {
      test('a refusal fails $name, it does not move', () async {
        final router = _router(
          ai,
          world,
          policy: policy,
          confirmCloud: (_) => false,
        );
        await expectLater(
          router.generate(prompt: 'hi', pin: pin),
          throwsA(
            isA<HybridRoutingException>().having(
              (e) => e.status,
              'status',
              StatusCode.permissionDenied,
            ),
          ),
        );
        expect(world.localCalls + world.cloudCalls, 0);
      });
    }

    test('a cancel while it is asked aborts the call', () async {
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final controller = CancellationController();
      final never = Completer<bool>();
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
        confirmCloud: (_) {
          controller.cancel('stop');
          return never.future;
        },
      );
      final r = await router.generate(prompt: 'hi', cancel: controller.token);
      expect(r.finishReason, FinishReason.aborted);
      expect(world.cloudCalls, 0);
    });

    test('a cancel while the cascade judges aborts the call', () async {
      final controller = CancellationController();
      final never = Completer<bool>();
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          fallback: const [kCloud],
          cascade: (_) {
            controller.cancel('stop');
            return never.future;
          },
        ).withRule(kOnDevice),
      );
      final r = await router.generate(prompt: 'hi', cancel: controller.token);
      expect(r.finishReason, FinishReason.aborted);
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

    test('after a move the stamp names the target that ran', () async {
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: const RoutePolicy(fallback: [kCloud]).withRule(kOnDevice),
      );
      final r1 = await router.generate(
        prompt: 'please confirm',
        toolNames: ['confirm'],
      );
      expect(r1.finishReason, FinishReason.interrupted);
      expect(r1.route!.target, kCloud);
      world.localThrows = null;
      final r2 = await router.generate(
        messages: r1.messages,
        toolNames: ['confirm'],
        interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
      );
      expect(r2.route!.source, RouteSource.resume);
      expect(r2.route!.target, kCloud);
      expect(r2.text, 'cloud answer');
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

    for (final (name, stamp) in [
      ('another router\'s', {'router': 'other', 'target': kCloud}),
      ('an unknown target\'s', {'router': 'hybrid-router', 'target': 'x'}),
    ]) {
      test('$name stamp reads as no stamp', () async {
        world.nextLabel = 'hard';
        final router = _router(ai, world);
        final r1 = await router.generate(
          prompt: 'please confirm',
          toolNames: ['confirm'],
        );
        final foreign = [
          ...r1.messages.take(r1.messages.length - 1),
          Message.fromJson({
            ...r1.messages.last.toJson(),
            'metadata': {'hybrid': stamp},
          }),
        ];
        final r2 = await router.generate(
          messages: foreign,
          toolNames: ['confirm'],
          interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
        );
        expect(r2.route!.target, kOnDevice);
        expect(r2.route!.reason, 'no stamp');
      });
    }

    test('without a stamp and without a device target is refused', () async {
      final router = _router(
        ai,
        world,
        targets: {kCloud: HybridTarget.cloud(cloudRef)},
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('c', (_) => const RouteDecision.prefer(kCloud)),
          ],
        ),
      );
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
      await expectLater(
        router.generate(
          messages: unstamped,
          toolNames: ['confirm'],
          interruptRespond: [InterruptResponse(r1.interrupts.first, 'ok')],
        ),
        throwsA(
          isA<HybridRoutingException>().having(
            (e) => e.status,
            'status',
            StatusCode.failedPrecondition,
          ),
        ),
      );
      expect(world.cloudCalls, 1);
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

  group('route info', () {
    test('is added to a copy, keeping the provider\'s custom and '
        'metadata', () async {
      final cached = ModelResponse(
        finishReason: FinishReason.stop,
        message: Message(
          role: Role.model,
          content: [TextPart(text: 'cached')],
          metadata: {'provider': 'm'},
        ),
        custom: {'provider': 'c'},
      );
      world.cloudResponse = cached;
      final router = _router(ai, world);
      final r = await router.generate(prompt: 'hi', pin: kCloud);
      expect(r.text, 'cached');
      expect(r.custom!['provider'], 'c');
      expect(r.message!.metadata!['provider'], 'm');
      expect(r.route!.target, kCloud);
      expect(cached.custom, {'provider': 'c'});
      await router.generate(prompt: 'again', pin: kCloud);
      expect(cached.custom, {'provider': 'c'});
    });
  });

  group('target config', () {
    test('each request gets its own copy', () async {
      final seen = <Object?>[];
      ai.defineModel(
        name: 'configured',
        fn: (req, _) async {
          seen.add(req.config?['maxTokens']);
          req.config!['maxTokens'] = 1; // a model that edits its config
          return _reply(req, 'configured');
        },
      );
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(
            modelRef('configured', config: {'maxTokens': 4096}),
          ),
        },
        policy: RoutePolicy(
          rules: [
            RouteRule.custom('dev', (_) => const RouteDecision.only(kOnDevice)),
          ],
        ),
      );
      await router.generate(prompt: 'one');
      await router.generate(prompt: 'two');
      expect(seen, [4096, 4096]);
    });

    test('a config that cannot be JSON is refused at definition', () {
      expect(
        () => _router(
          ai,
          world,
          targets: {
            kOnDevice: HybridTarget.onDevice(
              modelRef('local', config: _BrokenConfig()),
            ),
          },
          policy: RoutePolicy(
            rules: [
              RouteRule.custom(
                'dev',
                (_) => const RouteDecision.only(kOnDevice),
              ),
            ],
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('no toJson here'),
          ),
        ),
      );
    });
  });

  group('ownership of refusals', () {
    test('a refusal inside a tool fails the outer call, not as its '
        'refusal', () async {
      final router = _router(
        ai,
        world,
        policies: {
          'dev': RoutePolicy(
            rules: [
              RouteRule.custom(
                'dev',
                (_) => const RouteDecision.only(kOnDevice),
              ),
            ],
          ),
          'none': const RoutePolicy(),
        },
      );
      ai.defineTool(
        name: 'sub',
        description: 'asks the router with a policy that decides nothing',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          final inner = await router.generate(policy: 'none', prompt: 'x');
          return .response(inner.text);
        },
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['sub']);
      expect(r.finishReason, FinishReason.failed);
      expect(r.finishMessage, contains('decided nothing'));
    });

    test('a refusal a tool rethrows from a plain call is not the outer '
        'call\'s', () async {
      final router = _router(
        ai,
        world,
        policies: {
          'dev': RoutePolicy(
            rules: [
              RouteRule.custom(
                'dev',
                (_) => const RouteDecision.only(kOnDevice),
              ),
            ],
          ),
          'none': const RoutePolicy(),
        },
      );
      ai.defineTool(
        name: 'sub',
        description: 'rethrows what a plain routed call failed on',
        inputSchema: .map(.string(), .dynamicSchema()),
        fn: (input, _) async {
          final inner = await ai.generate(
            prompt: 'x',
            use: [router(policy: 'none')],
          );
          throw inner.cause!;
        },
      );
      final r = await router.generate(prompt: 'hi', toolNames: ['sub']);
      expect(r.finishReason, FinishReason.failed);
    });

    test(
      'a refusal a cascade judge rethrows is not the outer call\'s',
      () async {
        late final HybridRouter router;
        router = _router(
          ai,
          world,
          policies: {
            'judged': RoutePolicy(
              fallback: const [kCloud],
              cascade: (_) async {
                final inner = await ai.generate(
                  prompt: 'x',
                  use: [router(policy: 'none')],
                );
                throw inner.cause!;
              },
            ).withRule(kOnDevice),
            'none': const RoutePolicy(),
          },
        );
        final r = await router.generate(prompt: 'hi');
        expect(r.finishReason, FinishReason.failed);
        expect(r.finishMessage, contains('decided nothing'));
      },
    );
  });

  group('warm-up', () {
    RoutePolicy byClassifier(RouteClassifier c) => RoutePolicy(
      classifier: c,
      labels: const {'easy': RouteDecision.prefer(kOnDevice)},
    );

    test('warms each classifier once and each on-device target with its '
        'model, all at once', () async {
      final shared = _WarmClassifier();
      final other = _WarmClassifier();
      final warmed = <ModelRef>[];
      final gate = Completer<void>();
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(
            localRef,
            warmUp: (model) async {
              warmed.add(model);
              await gate.future;
            },
          ),
          kCloud: HybridTarget.cloud(cloudRef),
        },
        policies: {
          'a': byClassifier(shared),
          'b': byClassifier(shared),
          'c': byClassifier(other),
        },
      );
      var finished = false;
      final done = router.warmUp().then((_) => finished = true);
      await pumpEventQueue();
      expect(shared.warmUps, 1);
      expect(other.warmUps, 1);
      expect(warmed.map((m) => m.name), ['local']);
      expect(finished, isFalse, reason: 'the target is still warming');
      gate.complete();
      await done;
      expect(finished, isTrue);
      expect(world.localCalls + world.cloudCalls, 0);
    });

    test('a failed warm-up fails warmUp once every warm-up ended', () async {
      final slow = Completer<void>();
      var slowEnded = false;
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(
            localRef,
            warmUp: (_) async {
              await slow.future;
              slowEnded = true;
            },
          ),
          kCloud: HybridTarget.cloud(cloudRef),
        },
        policy: byClassifier(_WarmClassifier(fails: StateError('no model'))),
      );
      final done = router.warmUp();
      var ended = false;
      unawaited(done.then((_) {}, onError: (Object _) => ended = true));
      await pumpEventQueue();
      expect(ended, isFalse, reason: 'it waits for the slow target');
      slow.complete();
      await expectLater(done, throwsStateError);
      expect(slowEnded, isTrue);
    });

    test(
      'a classifier and targets without a warm-up warm as nothing',
      () async {
        final router = _router(ai, world);
        await router.warmUp();
        expect(world.classifyCalls, 0);
      },
    );
  });

  group('re-entry', () {
    test(
      'an app middleware before the router may run the call twice',
      () async {
        final router = _router(ai, world);
        ai.defineGenerateMiddleware<Object?>(
          name: 'twice',
          create: (_, _) => _Twice(),
        );
        final r = await ai.generate(
          prompt: 'hi',
          use: [
            middlewareRef(name: 'twice'),
            router(),
          ],
        );
        expect(r.finishMessage, isNull);
        expect(r.text, 'local plain');
        expect(world.classifyCalls, 2);
        expect(world.localCalls, 2);
      },
    );
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
      final stream = bad.stream(null);
      await expectLater(
        stream.toList(),
        throwsA(isA<HybridRoutingException>()),
      );
      await expectLater(
        stream.onResult,
        throwsA(isA<HybridRoutingException>()),
      );
    });
  });

  group('built-in rules', () {
    RoutePolicy sized() => RoutePolicy(
      rules: [
        RouteRule.inputSize(maxChars: 5, small: kOnDevice, large: kCloud),
      ],
    );

    test('inputSize: at most maxChars is small, one more is large', () async {
      final router = _router(ai, world, policy: sized());
      expect((await router.generate(prompt: 'hello')).route!.target, kOnDevice);
      expect((await router.generate(prompt: 'hello!')).route!.target, kCloud);
    });

    test('inputSize counts the system prompt and the history', () async {
      final router = _router(ai, world, policy: sized());
      final r = await router.generate(system: 'abcd', prompt: 'de');
      expect(r.route!.target, kCloud);
      expect(r.route!.reason, 'over 5 characters');
      final history = [
        Message(
          role: Role.user,
          content: [TextPart(text: 'abc')],
        ),
        Message(
          role: Role.model,
          content: [TextPart(text: 'de')],
        ),
      ];
      final alone = await router.generate(prompt: 'f');
      expect(alone.route!.target, kOnDevice);
      final withHistory = await router.generate(
        messages: [
          ...history,
          Message(
            role: Role.user,
            content: [TextPart(text: 'f')],
          ),
        ],
      );
      expect(withHistory.route!.target, kCloud);
    });

    test('inputSize rejects a negative maxChars', () {
      expect(
        () =>
            RouteRule.inputSize(maxChars: -1, small: kOnDevice, large: kCloud),
        throwsArgumentError,
      );
    });

    test(
      'offline: online decides nothing, offline only on the device',
      () async {
        var online = true;
        world.localThrows = GenkitException(
          'down',
          status: StatusCode.unavailable,
        );
        final router = _router(
          ai,
          world,
          policy: RoutePolicy(
            rules: [
              RouteRule.offline(isOnline: () => online),
              RouteRule.custom('next', (_) => const RouteDecision.only(kCloud)),
            ],
            fallback: const [kCloud],
          ),
        );
        final up = await router.generate(prompt: 'hi');
        expect(up.route!.rule, 'next');
        online = false;
        final down = await router.generate(prompt: 'hi');
        expect(down.finishReason, FinishReason.failed);
        expect(world.cloudCalls, 1, reason: 'only the online call');
      },
    );

    test('budget: prefer the premium target while it holds, only the cheap '
        'one once spent', () async {
      var available = true;
      world.cloudThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final router = _router(
        ai,
        world,
        policy: RoutePolicy(
          rules: [
            RouteRule.budget(
              available: () => available,
              premium: kCloud,
              cheap: kOnDevice,
            ),
          ],
          fallback: const [kOnDevice, kCloud],
        ),
      );
      final held = await router.generate(prompt: 'hi');
      expect(held.route!.attempts, [kCloud, kOnDevice]);
      available = false;
      world.cloudThrows = null;
      final spent = await router.generate(prompt: 'hi');
      expect(spent.route!.attempts, [kOnDevice]);
      expect(spent.route!.reason, 'budget spent');
      // Spent is `only`: a failing device does not fall back to the cloud.
      world.localThrows = GenkitException(
        'down',
        status: StatusCode.unavailable,
      );
      final cloudBefore = world.cloudCalls;
      final failed = await router.generate(prompt: 'hi');
      expect(failed.finishReason, FinishReason.failed);
      expect(world.cloudCalls, cloudBefore);
    });
  });

  group('definition', () {
    for (final (name, policy) in [
      (
        'a built-in rule',
        RoutePolicy(
          rules: [
            RouteRule.inputSize(maxChars: 1, small: kOnDevice, large: 'x'),
          ],
        ),
      ),
      (
        'a label',
        RoutePolicy(
          classifier: _Classifier(_World()),
          labels: const {'a': RouteDecision.only('x')},
        ),
      ),
      (
        'onAbstain',
        RoutePolicy(
          classifier: _Classifier(_World()),
          onAbstain: const RouteDecision.only('x'),
        ),
      ),
      (
        'onUnavailable',
        RoutePolicy(
          classifier: _Classifier(_World()),
          onUnavailable: const RouteDecision.only('x'),
        ),
      ),
    ]) {
      test('rejects $name naming an unknown target', () {
        expect(() => _router(ai, world, policy: policy), throwsArgumentError);
      });
    }

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
            labels: const {'hard': RouteDecision.prefer(kCloud)},
          ),
        ),
        throwsArgumentError,
      );
    });

    test('keeps its own frozen copy of targets and policies', () async {
      final labels = <String, RouteDecision>{
        'easy': const RouteDecision.only(kOnDevice),
      };
      final fallback = <String>[kCloud];
      final supports = <ModelCapability>{ModelCapability.tools};
      final router = _router(
        ai,
        world,
        targets: {
          kOnDevice: HybridTarget.onDevice(localRef, supports: supports),
          kCloud: HybridTarget.cloud(cloudRef),
        },
        policy: RoutePolicy(
          classifier: _Classifier(world),
          labels: labels,
          fallback: fallback,
        ),
      );
      labels['easy'] = const RouteDecision.only(kCloud);
      fallback.add('nowhere');
      supports.clear();
      final r = await router.generate(prompt: 'hi', toolNames: ['lookup']);
      expect(r.route!.target, kOnDevice);
      expect(world.cloudCalls, 0);
      expect(
        () => router.policies['smart']!.labels['x'] = const RouteDecision.only(
          kCloud,
        ),
        throwsUnsupportedError,
      );
      expect(
        () => router.policies['smart']!.fallback.add(kCloud),
        throwsUnsupportedError,
      );
      expect(
        () => router.targets[kOnDevice]!.supports!.add(ModelCapability.json),
        throwsUnsupportedError,
      );
    });

    test('rejects a cloud target under the on-device key', () {
      expect(
        () => _router(
          ai,
          world,
          targets: {kOnDevice: HybridTarget.cloud(cloudRef)},
          policy: RoutePolicy(
            rules: [
              RouteRule.custom('c', (_) => const RouteDecision.only(kOnDevice)),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a target named twice in a fallback', () {
      expect(
        () => _router(
          ai,
          world,
          policy: const RoutePolicy(fallback: [kCloud, kCloud]),
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

/// Hands the rest of the chain a later turn than the one it got.
class _LaterTurn extends GenerateMiddleware {
  @override
  Future<GenerateResult> generate(
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResult> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
  ) => next(envelope.copyWith(currentTurn: 1), ctx);
}

/// A config whose toJson() throws.
class _BrokenConfig {
  Map<String, dynamic> toJson() => throw StateError('no toJson here');
}

/// Keeps the zone the model hook of the last call ran in.
class _CaptureZone extends GenerateMiddleware {
  static Zone? captured;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    )
    next,
  ) {
    captured = Zone.current;
    return next(request, ctx);
  }
}

/// A classifier that counts its warm-ups, or fails them with [fails].
final class _WarmClassifier extends RouteClassifier {
  _WarmClassifier({this.fails});

  final Object? fails;
  int warmUps = 0;

  @override
  String get name => 'warm';

  @override
  Future<void> warmUp({CancellationToken? cancel}) async {
    warmUps++;
    if (fails case final e?) throw e;
  }

  @override
  Future<RouteVerdict> classify(
    RouteRequest request, {
    CancellationToken? cancel,
  }) async => const RouteVerdict.label('easy');
}

/// An app middleware that answers in place of the model, after running
/// [fire] inside the model hook.
class _Rogue extends GenerateMiddleware {
  _Rogue(this.fire);

  final Future<void> Function() fire;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    )
    next,
  ) async {
    await fire();
    return ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [TextPart(text: 'rogue')],
      ),
    );
  }
}

/// An app middleware that runs the whole call twice, as a generate-level
/// retry would, and answers with the second run.
class _Twice extends GenerateMiddleware {
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
    await next(envelope, ctx);
    return next(envelope, ctx);
  }
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
