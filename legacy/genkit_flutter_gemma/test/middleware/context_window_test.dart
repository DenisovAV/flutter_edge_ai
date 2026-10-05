import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

import '../src/fake_runtime.dart';

/// Builds a single-text-part message with the given role.
Message _msg(Role role, String text) => Message(
  role: role,
  content: [TextPart(text: text)],
);

/// A minimal model-call context; the trimmer ignores it and forwards to `next`.
ActionFnArg<ModelResponseChunk, ModelRequest, void> _ctx() => (
  streamingRequested: false,
  sendChunk: (ModelResponseChunk _) {},
  context: null,
  inputStream: null,
  init: null,
);

void main() {
  group('ContextWindowMiddleware.model', () {
    // Captures the request the middleware forwards, so tests can assert on the
    // trimmed message list. Returns a trivial response (unused by assertions).
    late ModelRequest forwarded;
    Future<ModelResponse> capture(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    ) async {
      forwarded = request;
      return ModelResponse(finishReason: FinishReason.stop);
    }

    test('passes messages through unchanged when under budget', () async {
      final messages = [_msg(Role.user, 'hi'), _msg(Role.model, 'hello')];
      final request = ModelRequest(messages: messages);

      await ContextWindowMiddleware(
        maxInputTokens: 1000,
      ).model(request, _ctx(), capture);

      expect(forwarded.messages.map((m) => m.content.first.text).toList(), [
        'hi',
        'hello',
      ]);
    });

    test('drops the oldest non-system messages when over budget', () async {
      // Each 40-char text ≈ 10 tokens (chars/4). system ≈ 1 token.
      final request = ModelRequest(
        messages: [
          _msg(Role.system, 'sys.'), // 1 tok, must survive
          _msg(Role.user, 'a' * 40), // m1 oldest → dropped
          _msg(Role.model, 'b' * 40), // m2 → dropped (contiguous suffix)
          _msg(Role.user, 'c' * 40), // m3 newest → kept
        ],
      );

      await ContextWindowMiddleware(
        maxInputTokens: 15,
      ).model(request, _ctx(), capture);

      final texts = forwarded.messages.map((m) => m.content.first.text);
      expect(texts, ['sys.', 'c' * 40]);
    });

    test(
      'keeps every system message AND actually trims the user turns',
      () async {
        // Two systems (~2 tok each) + two 80-char users (~20 tok each). Budget 5
        // forces the older user out. Assert the FULL result — a loose "2 systems
        // survived" check would also pass if the trimmer trimmed nothing.
        final request = ModelRequest(
          messages: [
            _msg(Role.system, 'rule one'),
            _msg(Role.user, 'x' * 80), // dropped
            _msg(Role.system, 'rule two'),
            _msg(Role.user, 'y' * 80), // most-recent → kept
          ],
        );

        await ContextWindowMiddleware(
          maxInputTokens: 5,
        ).model(request, _ctx(), capture);

        final texts = forwarded.messages
            .map((m) => m.content.first.text)
            .toList();
        // Both systems (moved to front) + only the most-recent user; the older
        // user 'x'*80 is gone.
        expect(texts, ['rule one', 'rule two', 'y' * 80]);
      },
    );

    test(
      'over-budget history of only system messages is left untouched',
      () async {
        final request = ModelRequest(
          messages: [
            _msg(Role.system, 'a' * 400),
            _msg(Role.system, 'b' * 400),
          ],
        );

        await ContextWindowMiddleware(
          maxInputTokens: 5,
        ).model(request, _ctx(), capture);

        final texts = forwarded.messages.map((m) => m.content.first.text);
        expect(texts, [
          'a' * 400,
          'b' * 400,
        ], reason: 'system messages are never dropped, even over budget');
      },
    );

    test(
      'drops an orphaned leading model turn (never splits a turn pair)',
      () async {
        // Budget keeps [model1, user2] as the raw suffix, but model1 is an
        // orphan (its user1 was trimmed). The retained history must begin on a
        // user turn, so model1 is dropped too.
        final request = ModelRequest(
          messages: [
            _msg(Role.user, 'u' * 40), // user1 — trimmed (oldest)
            _msg(Role.model, 'm' * 40), // model1 — orphaned → also dropped
            _msg(Role.user, 'u2' * 20), // user2 — most recent, kept
          ],
        );

        await ContextWindowMiddleware(
          maxInputTokens: 20,
        ).model(request, _ctx(), capture);

        final roles = forwarded.messages.map((m) => m.role.value).toList();
        expect(
          roles.first,
          'user',
          reason: 'retained history must start on a user turn',
        );
        expect(roles, ['user']);
      },
    );

    test(
      'a media part is estimated as heavy (256 tokens), forcing a drop',
      () async {
        // An image turn (~256 tok) then a tiny text turn, under a budget of 10.
        // If the media term were ~0 the total (~1) would fit and BOTH would pass
        // through; counting it at 256 forces the image out, leaving the text.
        final imageTurn = Message(
          role: Role.user,
          content: [MediaPart(media: Media(url: 'data:image/png;base64,AAAA'))],
        );
        final request = ModelRequest(
          messages: [
            imageTurn, // ~256 tok, oldest → dropped
            _msg(Role.user, 'and now?'), // most recent → kept
          ],
        );

        await ContextWindowMiddleware(
          maxInputTokens: 10,
        ).model(request, _ctx(), capture);

        expect(
          forwarded.messages,
          hasLength(1),
          reason:
              'the 256-token image turn must be dropped under a budget of 10',
        );
        expect(forwarded.messages.single.content.first.isMedia, isFalse);
      },
    );

    test(
      'keeps the most recent message even if it alone exceeds budget',
      () async {
        final request = ModelRequest(
          messages: [
            _msg(Role.user, 'old'),
            _msg(Role.user, 'z' * 400), // ~100 tokens, far over budget
          ],
        );

        await ContextWindowMiddleware(
          maxInputTokens: 10,
        ).model(request, _ctx(), capture);

        expect(forwarded.messages, hasLength(1));
        expect(forwarded.messages.single.content.first.text, 'z' * 400);
      },
    );

    test('derives the budget from request maxTokens minus reserveOutputTokens '
        'when maxInputTokens is null', () async {
      // maxTokens 25, reserve 0 → input budget 25. Three 10-token turns (30)
      // overflow, so the oldest is dropped and the two newest (20) are kept.
      // All user turns to isolate the derive-budget math from the orphan-drop.
      final request = ModelRequest(
        messages: [
          _msg(Role.user, 'a' * 40),
          _msg(Role.user, 'b' * 40),
          _msg(Role.user, 'c' * 40),
        ],
        config: {'maxTokens': 25},
      );

      await ContextWindowMiddleware(
        reserveOutputTokens: 0,
      ).model(request, _ctx(), capture);

      final texts = forwarded.messages.map((m) => m.content.first.text);
      expect(texts, ['b' * 40, 'c' * 40]);
    });

    test('throws INVALID_ARGUMENT when the derived budget is <= 0', () async {
      // maxTokens 128 with the default 256 reserve → budget = -128. Fail loud
      // instead of silently deleting the whole history down to the last turn.
      final request = ModelRequest(
        messages: [_msg(Role.user, 'a' * 40), _msg(Role.user, 'b' * 40)],
        config: {'maxTokens': 128},
      );

      expect(
        () => ContextWindowMiddleware().model(request, _ctx(), capture),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
    });
  });

  group('ContextWindowMiddleware construction validation', () {
    test('rejects a non-positive maxInputTokens', () {
      expect(
        () => ContextWindowMiddleware(maxInputTokens: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ContextWindowMiddleware(maxInputTokens: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a negative reserveOutputTokens', () {
      // A negative reserve would enlarge the derived budget past the context
      // window and re-introduce the KV-overflow this middleware prevents.
      expect(
        () => ContextWindowMiddleware(reserveOutputTokens: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('trimContext ref + plugin registration', () {
    test(
      'trimContext() config is a serializable Map (survives _configToMap)',
      () {
        final ref = trimContext(maxInputTokens: 800, reserveOutputTokens: 128);

        expect(ref.name, kContextWindowMiddlewareName);
        // MUST be a Map, not a plain value class: Genkit's `_configToMap` nulls
        // out a config it cannot `toJson()`, which would drop every argument on
        // the reflection/Dev-UI path.
        expect(ref.config, isA<Map<String, dynamic>>());
        expect(ref.config?['maxInputTokens'], 800);
        expect(ref.config?['reserveOutputTokens'], 128);
      },
    );

    test('trimContext() omits absent keys (empty map, not nulls)', () {
      expect(trimContext().config, isEmpty);
      expect(trimContext(maxInputTokens: 500).config, {'maxInputTokens': 500});
    });

    test('plugin.middleware() registers the context-window def', () {
      final plugin = GenkitFlutterGemmaPlugin(
        models: [
          FlutterGemmaModelConfig(
            name: 'm',
            modelType: gemma.ModelType.gemmaIt,
          ),
        ],
      );

      final defs = plugin.middleware();

      expect(defs.map((d) => d.name), contains(kContextWindowMiddlewareName));
    });
  });

  group('trimContext through ai.generate(use:) — real pipeline', () {
    // This is the test that catches the config-drop bug: Genkit round-trips a
    // middleware ref's config through `_configToMap` (which calls `toJson()`),
    // so a config that does not serialize to a Map is nulled out before it
    // reaches the middleware factory — and `trimContext(maxInputTokens:)` would
    // silently behave like `trimContext()`.
    late FakeInferenceChat fakeChat;
    late Genkit ai;

    setUp(() {
      fakeChat = FakeInferenceChat();
      final fakeModel = FakeInferenceModel()..chatToReturn = fakeChat;
      ai = Genkit(
        plugins: [
          GenkitFlutterGemmaPlugin(
            models: [
              FlutterGemmaModelConfig(
                name: 'm',
                modelType: gemma.ModelType.gemmaIt,
              ),
            ],
            runtime: FakeRuntime(model: fakeModel),
          ),
        ],
      );
    });

    // 9 alternating turns (last is a user turn), each ~14 estimated tokens.
    List<Message> longHistory() => [
      for (var i = 0; i < 9; i++)
        _msg(i.isEven ? Role.user : Role.model, 'turn $i ${'x' * 40}'),
    ];

    test(
      'explicit maxInputTokens actually trims the forwarded history',
      () async {
        await ai.generate(
          model: flutterGemma.model('m'),
          messages: longHistory(),
          use: [trimContext(maxInputTokens: 20)], // tiny → must drop most turns
        );

        // With the config-drop bug the budget silently derives from the default
        // 1024 window, so all 9 turns reach the chat untrimmed. The tiny explicit
        // budget must leave only the most recent turn(s).
        expect(
          fakeChat.receivedMessages.length,
          lessThan(9),
          reason: 'trimContext(maxInputTokens: 20) must trim the history',
        );
      },
    );

    test('no middleware leaves the full history intact (control)', () async {
      await ai.generate(
        model: flutterGemma.model('m'),
        messages: longHistory(),
      );

      expect(fakeChat.receivedMessages.length, 9);
    });
  });
}
