import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/services/ai_engine.dart';

RoutingContext _ctx({bool withImage = false}) => RoutingContext(
  request: ModelRequest(
    messages: [
      Message(
        role: Role.user,
        content: [
          TextPart(text: 'hi'),
          if (withImage)
            MediaPart(
              media: Media(
                contentType: 'image/png',
                url: 'data:image/png;base64,AA',
              ),
            ),
        ],
      ),
    ],
  ),
  branchKeys: const {kOnDevice, kCloud},
  isStreaming: false,
);

// Shared across groups below (registration wiring, cascade, cloud-absent).
Model fakeBranch(String name, String text, {void Function()? onCall}) => Model(
  name: name,
  fn: (request, context) async {
    onCall?.call();
    return ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [TextPart(text: text)],
      ),
    );
  },
);

// Records the request each branch actually received, so a test can assert on
// the config the branch was handed rather than on a canned return value.
Model capturingBranch(String name, List<ModelRequest?> seen) => Model(
  name: name,
  fn: (request, context) async {
    seen.add(request);
    return ModelResponse(
      finishReason: FinishReason.stop,
      message: Message(
        role: Role.model,
        content: [TextPart(text: name)],
      ),
    );
  },
);

void main() {
  test('cloud mode always routes to cloud', () {
    expect(AiEngine().strategyFor(PolicyMode.cloud).route(_ctx()), [kCloud]);
  });

  test('local mode always routes to on-device', () {
    expect(AiEngine().strategyFor(PolicyMode.local).route(_ctx()), [kOnDevice]);
  });

  test('smart mode: text is cloud-first with on-device fallback', () {
    expect(AiEngine().strategyFor(PolicyMode.smart).route(_ctx()), [
      kCloud,
      kOnDevice,
    ]);
  });

  test('smart mode: an image is routed to cloud only (capability)', () {
    // CapabilityStrategy excludes the text-only on-device model when an
    // image is present, since it declares no vision capability.
    final route = AiEngine()
        .strategyFor(PolicyMode.smart)
        .route(_ctx(withImage: true));
    expect(route, [kCloud]);
  });

  test('budget mode: premium while budget holds, cheap once spent', () {
    final e = AiEngine()
      ..budgetCap = 2
      ..cloudCallsSpent = 0;
    expect(e.strategyFor(PolicyMode.budget).route(_ctx()), [kCloud, kOnDevice]);
    e.cloudCallsSpent = 2;
    expect(e.strategyFor(PolicyMode.budget).route(_ctx()), [kOnDevice]);
  });

  // --------------------------------------------------------------------
  // The enum carries its own facts — dropdown label, text-only-ness, and
  // which branches its composite needs — so the UI and _registerPolicyModels
  // read them instead of re-deriving them. This table is the single place
  // those facts are pinned; a new mode without a row fails the first expect.
  test('PolicyMode carries label, textOnly and branch requirements', () {
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
        true,
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
  // End-to-end: modelFor -> ai.generate. This is the wiring `strategyFor`
  // alone never exercises — `strategyFor(mode).route(ctx)` only returns a
  // branch key, it never touches the registry. Before the fix, `modelFor`
  // built a fresh, never-registered `hybridModel`/`cascadeModel` on every
  // call; `ai.generate` reduces `model:` to `model.name` and looks it up via
  // `registry.lookupAction('model', name)`, so every real send threw
  // `GenkitException('Model <name> not found', NOT_FOUND)`. These tests fail
  // against that code and pass once `modelFor` returns a model that was
  // registered by `AiEngine`'s build+register path (see `AiEngine.forTest`).
  group('modelFor -> ai.generate (registration wiring)', () {
    test('cloud policy: modelFor is registered and routes to cloud', () async {
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: fakeBranch('flutter-edge-ai/local', 'LOCAL'),
        cloud: fakeBranch('googleai/cloud', 'CLOUD'),
      );

      final resp = await ai.generate(
        model: engine.modelFor(PolicyMode.cloud),
        prompt: 'hi',
      );

      expect(resp.text, 'CLOUD');
    });

    test(
      'local policy: modelFor is registered and routes to on-device',
      () async {
        final ai = Genkit(isDevEnv: false);
        final engine = AiEngine.forTest(
          ai: ai,
          local: fakeBranch('flutter-edge-ai/local', 'LOCAL'),
          cloud: fakeBranch('googleai/cloud', 'CLOUD'),
        );

        final resp = await ai.generate(
          model: engine.modelFor(PolicyMode.local),
          prompt: 'hi',
        );

        expect(resp.text, 'LOCAL');
      },
    );
  });

  // --------------------------------------------------------------------
  // Context budget: genkit_flutter_edge_ai reads `maxTokens` only from the
  // per-request config and defaults it to 1024, which the RAG prompt blows
  // past ("Input token ids are too long … 1713 >= 1024" on device). AiEngine
  // wraps the on-device branch so each request carries
  // kOnDeviceContextTokens — and only that branch: Gemini has no such key.
  group('on-device context budget', () {
    test('on-device branch is handed the 4096-token window', () async {
      final seen = <ModelRequest?>[];
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: capturingBranch('flutter-edge-ai/local', seen),
        cloud: fakeBranch('googleai/cloud', 'CLOUD'),
      );

      await ai.generate(model: engine.modelFor(PolicyMode.local), prompt: 'hi');

      expect(seen.single?.config?['maxTokens'], kOnDeviceContextTokens);
    });

    test('cloud branch is handed no maxTokens', () async {
      final seen = <ModelRequest?>[];
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: fakeBranch('flutter-edge-ai/local', 'LOCAL'),
        cloud: capturingBranch('googleai/cloud', seen),
      );

      await ai.generate(model: engine.modelFor(PolicyMode.cloud), prompt: 'hi');

      expect(seen.single?.config?['maxTokens'], isNull);
    });

    test('an explicit maxTokens on the request wins', () async {
      final seen = <ModelRequest?>[];
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: capturingBranch('flutter-edge-ai/local', seen),
        cloud: fakeBranch('googleai/cloud', 'CLOUD'),
      );

      await ai.generate(
        model: engine.modelFor(PolicyMode.local),
        prompt: 'hi',
        config: <String, dynamic>{'maxTokens': 2048},
      );

      expect(seen.single?.config?['maxTokens'], 2048);
    });

    // The one that actually holds the wrapper's copy-don't-mutate shape in
    // place. Cascade drives BOTH branches over the very same ModelRequest
    // object (genkit_hybrid's runInOrder passes one `request` to every
    // branch), on-device first. A wrapper that merged with
    // `request.config = ...` instead of copying would pass every other test
    // here and still hand Gemini a Gemma-only maxTokens on each escalation.
    test('cascade escalation does not leak maxTokens to cloud', () async {
      final seen = <ModelRequest?>[];
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: fakeBranch('flutter-edge-ai/local', 'short'), // <=20 -> escalate
        cloud: capturingBranch('googleai/cloud', seen),
      );

      await ai.generate(
        model: engine.modelFor(PolicyMode.cascade),
        prompt: 'hi',
      );

      expect(seen.single?.config?['maxTokens'], isNull);
    });
  });

  // --------------------------------------------------------------------
  // Cascade: escalates to cloud when the on-device response is too short
  // (per _buildModel's `accept: (r) => r.text.trim().length > 20`), and
  // stays on-device — without ever calling cloud — when it's long enough.
  group('cascade escalation', () {
    test('short on-device response escalates to the cloud branch', () async {
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: fakeBranch('flutter-edge-ai/local', 'short'), // <=20 chars
        cloud: fakeBranch(
          'googleai/cloud',
          'a sufficiently long cloud response, well past 20 chars',
        ),
      );

      final resp = await ai.generate(
        model: engine.modelFor(PolicyMode.cascade),
        prompt: 'hi',
      );

      expect(
        resp.text,
        'a sufficiently long cloud response, well past 20 chars',
      );
    });

    test('long on-device response is accepted without calling cloud', () async {
      var cloudCalls = 0;
      final ai = Genkit(isDevEnv: false);
      final engine = AiEngine.forTest(
        ai: ai,
        local: fakeBranch(
          'flutter-edge-ai/local',
          'a sufficiently long on-device response, well past 20 chars',
        ),
        cloud: fakeBranch(
          'googleai/cloud',
          'CLOUD',
          onCall: () => cloudCalls++,
        ),
      );

      final resp = await ai.generate(
        model: engine.modelFor(PolicyMode.cascade),
        prompt: 'hi',
      );

      expect(
        resp.text,
        'a sufficiently long on-device response, well past 20 chars',
      );
      expect(cloudCalls, 0);
    });
  });

  // --------------------------------------------------------------------
  // Cloud-absent guard: no API key -> AiEngine.forTest omits `cloud` (it's
  // already nullable) -> _registerPolicyModels only registers the modes whose
  // `PolicyMode.availableWith` holds — here just `local`.
  group('cloud-absent guard', () {
    test(
      'local works without a cloud branch; every cloud-needing policy throws',
      () {
        final ai = Genkit(isDevEnv: false);
        final engine = AiEngine.forTest(
          ai: ai,
          local: fakeBranch('flutter-edge-ai/local', 'LOCAL'),
        );

        expect(engine.cloudReady, isFalse);
        expect(engine.modelFor(PolicyMode.local), isNotNull);
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
            () => engine.modelFor(mode),
            throwsA(isA<StateError>()),
            reason: '${mode.name} needs the cloud branch',
          );
        }
      },
    );
  });

  // --------------------------------------------------------------------
  // Local-absent guard: symmetric mirror of the cloud-absent guard above —
  // this is the unit-level proxy for item 2's cloud/local decoupling. If the
  // on-device engine bootstrap ever throws again before Genkit is built,
  // cloud must still resolve and work; here that's modeled directly via
  // `AiEngine.forTest(local: null)` (the same nullable seam `forTest` and
  // `initialize` now share).
  group('local-absent guard', () {
    test(
      'cloud works without a local branch; every local-needing policy throws',
      () async {
        final ai = Genkit(isDevEnv: false);
        final engine = AiEngine.forTest(
          ai: ai,
          cloud: fakeBranch('googleai/cloud', 'CLOUD'),
        );

        expect(engine.localReady, isFalse);

        final resp = await ai.generate(
          model: engine.modelFor(PolicyMode.cloud),
          prompt: 'hi',
        );
        expect(resp.text, 'CLOUD');

        // Same shape as the cloud-absent guard: read the fixture's readiness,
        // and pin the count so the loop can never go vacuously green.
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
            () => engine.modelFor(mode),
            throwsA(isA<StateError>()),
            reason: '${mode.name} needs the on-device branch',
          );
        }
      },
    );
  });
}
