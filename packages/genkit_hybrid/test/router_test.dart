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
      expect(r.route!.reason, 'fallback: cloud failed with TimeoutException');
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
      expect(r.route!.reason, 'fallback: onDevice failed with UNAVAILABLE');
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
