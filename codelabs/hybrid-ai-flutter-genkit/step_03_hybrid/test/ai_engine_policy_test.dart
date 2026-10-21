import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart' show googleAI;
import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/services/ai_engine.dart';

const _localName = 'local';
final _cloudRef = modelRef('fakecloud/gemini');

/// What the fake models received and how they answer, per test.
class _Models {
  String localText = 'LOCAL';
  String cloudText = 'CLOUD';
  Object? cloudThrows;
  final localSeen = <ModelRequest>[];
  final cloudSeen = <ModelRequest>[];
}

ModelResponse _answer(String text) => ModelResponse(
  finishReason: FinishReason.stop,
  message: Message(
    role: Role.model,
    content: [TextPart(text: text)],
  ),
);

/// Stands in for genkit_google_genai: resolves `fakecloud/<any>`. It goes to
/// the router only, as the real Gemini plugin does.
class _FakeCloud extends GenkitPlugin {
  _FakeCloud(this.models);

  final _Models models;

  @override
  String get name => 'fakecloud';

  @override
  Action? resolve(ActionType actionType, String name) =>
      actionType == ActionType.model
      ? Model(
          name: 'fakecloud/$name',
          fn: (request, _) async {
            models.cloudSeen.add(request);
            if (models.cloudThrows case final e?) throw e;
            return _answer(models.cloudText);
          },
        )
      : null;
}

/// An engine over fake targets: the on-device model is registered in the
/// app's Genkit under the plugin's name, the cloud one comes from a plugin
/// only the router gets. Either can be left out.
AiEngine _engine(_Models models, {bool local = true, bool cloud = true}) {
  final ai = Genkit(isDevEnv: false, promptDir: null);
  addTearDown(ai.shutdown);
  if (local) {
    ai.defineModel(
      name: onDeviceModel(_localName).name,
      fn: (request, _) async {
        models.localSeen.add(request);
        return _answer(models.localText);
      },
    );
  }
  return AiEngine.forTest(
    ai: ai,
    localModel: local ? _localName : null,
    cloudModel: cloud ? _cloudRef : null,
    cloudPlugin: cloud ? _FakeCloud(models) : null,
  );
}

Message _user({bool withImage = false}) => Message(
  role: Role.user,
  content: [
    TextPart(text: 'hi'),
    if (withImage)
      MediaPart(
        media: Media(contentType: 'image/png', url: 'data:image/png;base64,AA'),
      ),
  ],
);

Future<GenerateResult> _send(
  AiEngine engine,
  PolicyMode mode, {
  bool withImage = false,
}) => engine.router.generate(
  policy: engine.policyName(mode),
  messages: [_user(withImage: withImage)],
);

void main() {
  // --------------------------------------------------------------------
  // The pure mode → policy mapping: what each policy's rule decides.
  test('cloud and local modes pin their target', () {
    final request = RouteRequest(GenerateActionOptions(messages: [_user()]));
    final engine = AiEngine();
    final cloud = engine.policyFor(PolicyMode.cloud).rules.single;
    final local = engine.policyFor(PolicyMode.local).rules.single;
    expect(cloud.decide(request)!.target, kCloud);
    expect(cloud.decide(request)!.isOnly, isTrue);
    expect(local.decide(request)!.target, kOnDevice);
    expect(local.decide(request)!.isOnly, isTrue);
  });

  test('budget mode: cloud while the budget holds, only on-device once '
      'spent', () {
    final request = RouteRequest(GenerateActionOptions(messages: [_user()]));
    final engine = AiEngine()
      ..budgetCap = 2
      ..cloudCallsSpent = 0;
    final rule = engine.policyFor(PolicyMode.budget).rules.single;
    expect(rule.decide(request)!.target, kCloud);
    engine.cloudCallsSpent = 2;
    expect(rule.decide(request)!.target, kOnDevice);
    expect(rule.decide(request)!.isOnly, isTrue);
  });

  // --------------------------------------------------------------------
  // The enum carries its own facts — dropdown label, text-only-ness, and
  // which targets its policy needs — so the UI and the router definition
  // read them instead of re-deriving them. This table is the single place
  // those facts are pinned; a new mode without a row fails the first expect.
  test('PolicyMode carries label, textOnly and target requirements', () {
    // mode -> (label, textOnly, availableWith over the four (cloud, local)
    // combinations in `combos` order).
    const combos = [(false, false), (false, true), (true, false), (true, true)];
    const expected = <PolicyMode, (String, bool, List<bool>)>{
      PolicyMode.cloud: ('Cloud', false, [false, false, true, true]),
      PolicyMode.local: ('Local', true, [false, true, false, true]),
      PolicyMode.smart: (
        'Smart (image-aware)',
        false,
        [false, false, false, true],
      ),
      PolicyMode.cascade: (
        'Cascade (escalate on quality)',
        false,
        [false, false, false, true],
      ),
      PolicyMode.budget: (
        'Budget (cost-gated)',
        false,
        [false, false, false, true],
      ),
    };

    expect(expected.keys, PolicyMode.values, reason: 'a new mode needs a row');

    for (final MapEntry(key: mode, value: (label, textOnly, availability))
        in expected.entries) {
      expect(mode.label, label, reason: '${mode.name} label');
      expect(mode.textOnly, textOnly, reason: '${mode.name} textOnly');
      expect(
        [
          for (final (cloud, local) in combos)
            mode.availableWith(cloud: cloud, local: local),
        ],
        availability,
        reason: '${mode.name} availableWith',
      );
    }
  });

  // --------------------------------------------------------------------
  // End to end through the router the engine defines.
  group('router', () {
    test('cloud mode answers from the cloud', () async {
      final models = _Models();
      final r = await _send(_engine(models), PolicyMode.cloud);
      expect(r.text, 'CLOUD');
      expect(r.route!.target, kCloud);
    });

    test('local mode answers on the device', () async {
      final models = _Models();
      final r = await _send(_engine(models), PolicyMode.local);
      expect(r.text, 'LOCAL');
      expect(r.route!.target, kOnDevice);
    });

    test('smart mode: text falls back to the device when the cloud is '
        'down', () async {
      final models = _Models()
        ..cloudThrows = GenkitException(
          'offline',
          status: StatusCode.unavailable,
        );
      final r = await _send(_engine(models), PolicyMode.smart);
      expect(r.text, 'LOCAL');
      expect(r.route!.attempts, [kCloud, kOnDevice]);
    });

    test('smart mode: an image never falls back to the text-only '
        'device', () async {
      final models = _Models()
        ..cloudThrows = GenkitException(
          'offline',
          status: StatusCode.unavailable,
        );
      final r = await _send(_engine(models), PolicyMode.smart, withImage: true);
      expect(r.finishReason, FinishReason.failed);
      expect(models.localSeen, isEmpty);
    });

    test('the router does not hand its cloud plugin to the app', () async {
      final models = _Models();
      final engine = _engine(models);
      final r = await engine.ai.generate(model: _cloudRef, prompt: 'hi');
      expect(r.finishReason, FinishReason.failed);
      expect(models.cloudSeen, isEmpty);
    });

    test('the app\'s own Genkit cannot resolve the cloud model', () async {
      final ai = AiEngine.appGenkit(embedders: false);
      addTearDown(ai.shutdown);
      final gemini = googleAI.gemini(kCloudModel).name;
      expect(await ai.registry.lookupAction(ActionType.model, gemini), isNull);
    });

    test('cascade sends an image straight to the cloud', () async {
      final models = _Models();
      final r = await _send(_engine(models), PolicyMode.cascade, withImage: true);
      expect(r.text, 'CLOUD');
      expect(r.route!.attempts, [kCloud]);
      expect(models.localSeen, isEmpty);
    });
  });

  // --------------------------------------------------------------------
  // Context budget: genkit_flutter_edge_ai reads `maxTokens` only from the
  // request's config and defaults it to 1024, which the RAG prompt blows
  // past ("Input token ids are too long … 1713 >= 1024" on device). The
  // on-device target carries kOnDeviceContextTokens as its config — and only
  // that target: Gemini has no such key.
  group('on-device context budget', () {
    test('the on-device target is handed the 4096-token window', () async {
      final models = _Models();
      await _send(_engine(models), PolicyMode.local);
      expect(
        models.localSeen.single.config?['maxTokens'],
        kOnDeviceContextTokens,
      );
    });

    test('the cloud target is handed no maxTokens', () async {
      final models = _Models();
      await _send(_engine(models), PolicyMode.cloud);
      expect(models.cloudSeen.single.config?['maxTokens'], isNull);
    });

    test('cascade escalation does not leak maxTokens to the cloud', () async {
      final models = _Models()..localText = 'short';
      await _send(_engine(models), PolicyMode.cascade);
      expect(models.cloudSeen.single.config?['maxTokens'], isNull);
    });
  });

  // --------------------------------------------------------------------
  // Cascade: escalates to the cloud when the on-device response is too short
  // (`result.text.trim().length > 20`), and stays on the device — without
  // ever calling the cloud — when it's long enough.
  group('cascade escalation', () {
    test('a short on-device response escalates to the cloud', () async {
      final models = _Models()
        ..localText = 'short'
        ..cloudText = 'a sufficiently long cloud response, well past 20 chars';
      final r = await _send(_engine(models), PolicyMode.cascade);
      expect(r.text, 'a sufficiently long cloud response, well past 20 chars');
      expect(r.route!.attempts, [kOnDevice, kCloud]);
    });

    test('a long on-device response is kept without calling the '
        'cloud', () async {
      final models = _Models()
        ..localText =
            'a sufficiently long on-device response, well past 20 chars';
      final r = await _send(_engine(models), PolicyMode.cascade);
      expect(
        r.text,
        'a sufficiently long on-device response, well past 20 chars',
      );
      expect(models.cloudSeen, isEmpty);
    });
  });

  // --------------------------------------------------------------------
  // Missing targets: no API key → no cloud target → only `local` has a
  // policy; no on-device model → only `cloud` has one.
  group('missing targets', () {
    test(
      'without the cloud only local works; every other mode throws',
      () async {
        final models = _Models();
        final engine = _engine(models, cloud: false);
        expect(engine.cloudReady, isFalse);
        expect((await _send(engine, PolicyMode.local)).text, 'LOCAL');
        // Filtered off the engine's own readiness (not literals) so the
        // filter can't drift from the fixture, and pinned to a length so an
        // `availableWith` that stopped excluding anything empties the loop
        // below into a vacuous green instead of failing here.
        final modes = PolicyMode.values
            .where(
              (m) => !m.availableWith(
                cloud: engine.cloudReady,
                local: engine.localReady,
              ),
            )
            .toList();
        expect(modes, hasLength(4));
        for (final mode in modes) {
          expect(
            () => engine.policyName(mode),
            throwsA(isA<StateError>()),
            reason: '${mode.name} needs the cloud target',
          );
        }
      },
    );

    test(
      'without the device only cloud works; every other mode throws',
      () async {
        final models = _Models();
        final engine = _engine(models, local: false);
        expect(engine.localReady, isFalse);
        expect((await _send(engine, PolicyMode.cloud)).text, 'CLOUD');
        final modes = PolicyMode.values
            .where(
              (m) => !m.availableWith(
                cloud: engine.cloudReady,
                local: engine.localReady,
              ),
            )
            .toList();
        expect(modes, hasLength(4));
        for (final mode in modes) {
          expect(
            () => engine.policyName(mode),
            throwsA(isA<StateError>()),
            reason: '${mode.name} needs the on-device target',
          );
        }
      },
    );
  });
}
