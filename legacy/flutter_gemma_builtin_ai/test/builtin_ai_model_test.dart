// The model is where the two flutter_gemma session lanes meet flutter_local_ai:
// `createSession` keeps a singleton (replacing and closing its predecessor)
// while `openSession` returns detached sessions. Both lanes are newly routed
// through `LocalAiModel`, so the bookkeeping on each side has to agree —
// `model.sessions` here, `host.sessions`/`host.closedIds` at the host.

import 'package:flutter_gemma/core/tool.dart' show Tool;
import 'package:flutter_gemma/core/registry/runtime_config.dart'
    show RuntimeConfig;
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart'
    show BuiltInAiEngine;
import 'package:flutter_gemma_builtin_ai/src/builtin_ai_model.dart'
    show BuiltInAiModel;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiModel, LocalAiTool, debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart';

import 'adapter_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAiHost host;

  setUp(() {
    host = FakeLocalAiHost();
    debugLocalAiHost = host;
  });

  tearDown(() async {
    debugLocalAiHost = null;
    await host.dispose();
  });

  Future<BuiltInAiModel> newModel([
    RuntimeConfig config = builtInConfig,
  ]) async {
    final model =
        await const BuiltInAiEngine().createModel(builtInSpec(), config)
            as BuiltInAiModel;
    addTearDown(model.close);
    return model;
  }

  group('session lanes', () {
    test('createSession replaces and closes the previous singleton', () async {
      final model = await newModel();

      final first = await model.createSession();
      final second = await model.createSession();

      // The superseded session's native context must be released, not leaked.
      expect(host.closedIds, [1]);
      expect(model.session, same(second));
      expect(model.sessions, [second]);
      expect(first, isNot(same(second)));
    });

    test(
      'concurrent createSession leaves only the latest session open',
      () async {
        final model = await newModel();

        final sessions = await Future.wait([
          model.createSession(),
          model.createSession(),
        ]);

        expect(model.session, same(sessions.last));
        expect(model.sessions, hasLength(1));
        expect(host.sessions.first.closed, isTrue);
      },
    );

    test('openSession leaves the singleton lane alone', () async {
      final model = await newModel();

      final singleton = await model.createSession();
      final detached = await model.openSession();

      expect(model.session, same(singleton));
      expect(model.sessions, containsAll([singleton, detached]));
      expect(host.closedIds, isEmpty);
    });

    test('closing an open session removes it from sessions', () async {
      final model = await newModel();
      final detached = await model.openSession();

      await detached.close();

      expect(model.sessions, isNot(contains(detached)));
    });

    test('maxConcurrentSessions caps open sessions and the slot frees on '
        'close', () async {
      final model = await newModel(
        const RuntimeConfig(
          maxTokens: 4096,
          modelPath: '',
          maxConcurrentSessions: 1,
        ),
      );

      final first = await model.openSession();
      await expectLater(model.openSession(), throwsStateError);

      await first.close();
      // The cap is a live count, not a high-water mark.
      await model.openSession();
    });

    test('audio is rejected rather than silently dropped', () async {
      final model = await newModel();

      await expectLater(
        model.createSession(enableAudioModality: true),
        throwsUnsupportedError,
      );
    });

    test('LoRA is refused on both session lanes', () async {
      final model = await newModel();

      await expectLater(
        model.createSession(loraPath: '/tmp/adapter.bin'),
        throwsUnsupportedError,
      );
      await expectLater(
        model.openSession(loraPath: '/tmp/adapter.bin'),
        throwsUnsupportedError,
      );
    });

    test(
      'systemInstruction, temperature and maxOutputTokens reach the host',
      () async {
        final model = await newModel();

        await model.createSession(
          systemInstruction: 'Be terse.',
          maxOutputTokens: 128,
          temperature: 0.3,
        );

        expect(host.sessions.single.systemInstruction, 'Be terse.');
        expect(host.sessions.single.maxOutputTokens, 128);
        expect(host.sessions.single.temperature, 0.3);
      },
    );

    test(
      'flutter_gemma tools are not handed to the native tool runner',
      () async {
        final model = await newModel();

        // InferenceChat owns function calling on this engine: it weaves the
        // declarations into the prompt and parses the calls back out. Passing
        // them natively as well would run two tool loops for one turn, so the
        // tools handed in here must NOT reach the host's native tool API.
        await model.createSession(
          tools: const [
            Tool(
              name: 'getWeather',
              description: 'Current conditions for a city.',
              parameters: {
                'type': 'object',
                'properties': {
                  'city': {'type': 'string'},
                },
              },
            ),
          ],
        );

        expect(host.sessions.single.toolNames, isEmpty);
      },
    );
  });

  group('escape hatch', () {
    test(
      'localAiModel exposes the underlying flutter_local_ai model',
      () async {
        final model = await newModel();

        expect(model.localAiModel, isA<LocalAiModel>());
      },
    );

    test('native tools preserve their schema through localAiModel', () async {
      final model = await newModel();
      // The capability flutter_gemma's interface has no slot for: Apple's
      // native tool calling, driven through flutter_local_ai's own API while
      // the flutter_gemma lane keeps its prompt-woven tools.
      final native = await model.localAiModel.openSession(
        tools: [
          LocalAiTool(
            name: 'lookup',
            description: 'Local lookup',
            parameterSchema: const {
              'type': 'object',
              'properties': {
                'query': {'type': 'string'},
                'kind': {
                  'type': 'string',
                  'enum': ['city', 'country'],
                },
              },
              'required': ['query', 'kind'],
            },
            onCall: (arguments) async => {'found': arguments['query']},
          ),
        ],
      );
      addTearDown(native.close);

      expect(host.session(native.sessionId)!.toolNames, ['lookup']);
      expect(host.session(native.sessionId)!.toolSchemas['lookup'], {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['city', 'country'],
          },
        },
        'required': ['query', 'kind'],
      });
      expect(
        await host.invokeTool(native.sessionId, 'lookup', {
          'query': 'Rome',
          'kind': 'city',
        }),
        '{"found":"Rome"}',
      );
    });
  });

  group('close', () {
    test(
      'closing the model closes it at the host and empties sessions',
      () async {
        final model = await newModel();
        await model.createSession();

        await model.close();

        expect(host.modelClosed, isTrue);
        expect(model.sessions, isEmpty);
      },
    );

    test('close listeners fire so core can reset its bookkeeping', () async {
      final model = await newModel();
      var notified = false;
      model.addCloseListener(() => notified = true);

      await model.close();

      expect(notified, isTrue);
    });
  });
}
