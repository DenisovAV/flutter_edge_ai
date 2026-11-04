// A response format on built-in AI: which platforms take one, which schemas
// are refused before a session opens, what reaches flutter_local_ai, and how
// each structured turn ends. Driven through core's openSession/openChat, so
// core's checks run over the engine's answers as they do in an app.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_edge_ai/engine.dart'
    show
        IncompleteStructuredOutputException,
        InferenceModel,
        InferenceModelSession,
        JsonSchemaResponseFormat,
        Message,
        NonConformingStructuredOutputException,
        ResponseFormat,
        ResponseFormatUnsupportedException,
        StructuredDelivery,
        TextResponse,
        TurnEnd;
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart'
    show BuiltInAiEngine;
import 'package:flutter_edge_ai_builtin_ai/src/builtin_ai_session.dart'
    show BuiltInAiSession;
import 'package:flutter_edge_ai_builtin_ai/src/structured_output.dart'
    show
        BuiltInPlatform,
        builtInSchemaKeywords,
        builtInSchemaRefusal,
        builtInStructuredOutputSupport,
        debugVerifiedBuiltInPlatforms;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiGenerationException, debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart';

import 'adapter_test_support.dart';

final _codeFormat = ResponseFormat.jsonSchema({
  'type': 'object',
  'properties': {
    'code': {
      'enum': ['qzx-7', 'vlo-3'],
    },
  },
  'required': ['code'],
});

const _codeReply = '{"code":"vlo-3"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAiHost host;

  void install(FakeLocalAiHost fake) {
    host = fake;
    debugLocalAiHost = fake;
    addTearDown(fake.dispose);
  }

  setUp(() => install(FakeLocalAiHost()));

  tearDown(() {
    debugLocalAiHost = null;
    debugDefaultTargetPlatformOverride = null;
    debugVerifiedBuiltInPlatforms = null;
  });

  /// A built-in model on macOS, with macOS taken as verified so the
  /// structured path runs.
  Future<InferenceModel> macModel() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    debugVerifiedBuiltInPlatforms = {BuiltInPlatform.apple};
    final model = await const BuiltInAiEngine().createModel(
      builtInSpec(),
      builtInConfig,
    );
    addTearDown(model.close);
    return model;
  }

  Future<String> askStructured(InferenceModel model) async {
    final session = await model.openSession(responseFormat: _codeFormat);
    addTearDown(session.close);
    await session.addQueryChunk(const Message(text: 'A poem', isUser: true));
    return session.getResponse();
  }

  group('support per platform', () {
    test('verified macOS: the keyword set, buffered', () async {
      final support = (await macModel()).structuredOutputSupport;
      expect(support.isSupported, isTrue);
      expect(support.keywords, builtInSchemaKeywords);
      expect(support.delivery, StructuredDelivery.buffered);
    });

    test('no platform is verified yet', () {
      for (final platform in BuiltInPlatform.values) {
        expect(builtInStructuredOutputSupport(platform).isSupported, isFalse);
      }
    });

    test('Android is refused even when listed as verified', () {
      debugVerifiedBuiltInPlatforms = BuiltInPlatform.values.toSet();
      expect(
        builtInStructuredOutputSupport(BuiltInPlatform.android).isSupported,
        isFalse,
      );
      expect(
        builtInStructuredOutputSupport(BuiltInPlatform.none).isSupported,
        isFalse,
      );
    });

    for (final (platform, target) in [
      (BuiltInPlatform.apple, TargetPlatform.macOS),
      (BuiltInPlatform.appleIos, TargetPlatform.iOS),
      (BuiltInPlatform.windows, TargetPlatform.windows),
      (BuiltInPlatform.android, TargetPlatform.android),
    ]) {
      test('${target.name}: refused with a reason', () async {
        debugDefaultTargetPlatformOverride = target;
        final model = await const BuiltInAiEngine().createModel(
          builtInSpec(),
          builtInConfig,
        );
        addTearDown(model.close);
        final support = model.structuredOutputSupport;
        expect(support.isSupported, isFalse);
        expect(support.reason, builtInStructuredOutputSupport(platform).reason);
        expect(support.reason, isNotEmpty);
      });
    }

    // No model is created on these: Chrome is not a VM test, and Linux has
    // no built-in model.
    for (final platform in [BuiltInPlatform.chrome, BuiltInPlatform.none]) {
      test('${platform.name}: refused with a reason', () {
        final support = builtInStructuredOutputSupport(platform);
        expect(support.isSupported, isFalse);
        expect(support.reason, isNotEmpty);
      });
    }

    test('Android: refused before anything reaches the host', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final model = await const BuiltInAiEngine().createModel(
        builtInSpec(),
        builtInConfig,
      );
      addTearDown(model.close);
      host.calls.clear();
      await expectLater(
        model.openSession(responseFormat: _codeFormat),
        throwsA(
          isA<ResponseFormatUnsupportedException>()
              .having((e) => e.schemaPath, 'schemaPath', isNull)
              .having((e) => e.message, 'message', contains('ML Kit')),
        ),
      );
      expect(host.calls, isEmpty);
    });
  });

  group('refused schemas', () {
    final cases = <String, (Map<String, Object?>, String?)>{
      'jsonObject(): a property-less root object': (
        {'type': 'object'},
        '/type',
      ),
      'a property-less nested object': (
        {
          'type': 'object',
          'properties': {
            'o': {'type': 'object'},
          },
        },
        '/properties/o/type',
      ),
      'a non-string enum': (
        {
          'type': 'object',
          'properties': {
            'n': {
              'enum': [1, 2],
            },
          },
        },
        '/properties/n/enum',
      ),
      'a string enum on another type': (
        {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'integer',
              'enum': ['1'],
            },
          },
        },
        '/properties/n/type',
      ),
      'a null type': (
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'null'},
          },
        },
        '/properties/n/type',
      ),
      'an array with no items': (
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'array'},
          },
        },
        '/properties/a/type',
      ),
      'an array of property-less objects': (
        {
          'type': 'array',
          'items': {'type': 'object'},
        },
        '/items/type',
      ),
      // Outside the keyword set: core refuses them before the engine's own
      // refusal is asked.
      'additionalProperties': (
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
          },
          'additionalProperties': false,
        },
        '/additionalProperties',
      ),
      'a numeric bound': (
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer', 'minimum': 0},
          },
        },
        '/properties/n/minimum',
      ),
      'const': (
        {
          'type': 'object',
          'properties': {
            'c': {'const': 'x'},
          },
        },
        '/properties/c/const',
      ),
    };

    for (final MapEntry(key: name, value: (schema, path)) in cases.entries) {
      test(name, () async {
        final model = await macModel();
        final refusal = model.refusalFor(ResponseFormat.jsonSchema(schema));
        expect(refusal, isNotNull);
        expect(refusal!.schemaPath, path);
        host.calls.clear();
        await expectLater(
          model.openSession(responseFormat: ResponseFormat.jsonSchema(schema)),
          throwsA(isA<ResponseFormatUnsupportedException>()),
        );
        expect(host.calls, isEmpty);
      });
    }

    test('a property-less object is refused on Apple only', () {
      final format = ResponseFormat.jsonObject() as JsonSchemaResponseFormat;
      expect(builtInSchemaRefusal(format, BuiltInPlatform.apple), isNotNull);
      expect(builtInSchemaRefusal(format, BuiltInPlatform.appleIos), isNotNull);
      expect(builtInSchemaRefusal(format, BuiltInPlatform.chrome), isNull);
      expect(builtInSchemaRefusal(format, BuiltInPlatform.windows), isNull);
    });

    test('the keyword set, nested, is accepted', () async {
      final model = await macModel();
      final format = ResponseFormat.jsonSchema({
        'type': 'object',
        'title': 'Cat',
        'properties': {
          'name': {'type': 'string', 'description': 'The name'},
          'age': {'type': 'integer'},
          'mood': {
            'type': 'string',
            'enum': ['calm', 'wild'],
          },
          'toys': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
              },
              'required': ['kind'],
            },
            'minItems': 1,
            'maxItems': 3,
          },
        },
        'required': ['name', 'age'],
      });
      expect(model.refusalFor(format), isNull);
    });
  });

  group('a structured turn', () {
    test('sends the schema and answers in one chunk', () async {
      final model = await macModel();
      host.response = _codeReply;
      final session = await model.openSession(responseFormat: _codeFormat);
      addTearDown(session.close);
      await session.addQueryChunk(const Message(text: 'A poem', isUser: true));

      final chunks = await session.getResponseAsync().toList();

      expect(chunks, [_codeReply]);
      expect(host.calls, contains('generateStructuredResponse'));
      expect(host.calls, isNot(contains('generateResponseAsync')));
      expect(
        jsonDecode(host.sessions.single.lastSchemaJson!),
        (_codeFormat as JsonSchemaResponseFormat).schema,
      );
    });

    test('getResponse returns the value', () async {
      final model = await macModel();
      host.response = _codeReply;
      expect(await askStructured(model), _codeReply);
    });

    test('a plain session on the same model sends no schema', () async {
      final model = await macModel();
      host.response = _codeReply;
      await askStructured(model);
      host.calls.clear();

      final plain = await model.openSession();
      addTearDown(plain.close);
      expect(plain, isA<BuiltInAiSession>());
      await plain.addQueryChunk(const Message(text: 'Hi', isUser: true));
      await plain.getResponse();

      expect(host.calls, contains('generateResponse'));
      expect(host.calls, isNot(contains('generateStructuredResponse')));
    });

    test(
      'a reply that is not a value of the format is non-conforming',
      () async {
        final model = await macModel();
        host.response = '{"code":"other"}';
        await expectLater(
          askStructured(model),
          throwsA(isA<NonConformingStructuredOutputException>()),
        );
      },
    );

    test('a full context window ends the turn as contextLimit', () async {
      final model = await macModel();
      for (final code in ['contextSizeExceeded', 'exceededContextWindowSize']) {
        host.generateResponseError = LocalAiGenerationException(
          'too long',
          errorCode: code,
        );
        await expectLater(
          askStructured(model),
          throwsA(
            isA<IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', TurnEnd.contextLimit)
                .having((e) => e.partialText, 'partialText', ''),
          ),
        );
      }
    });

    test('any other failure is passed on as it is', () async {
      final model = await macModel();
      final failure = LocalAiGenerationException(
        'guardrail',
        errorCode: 'guardrailViolation',
      );
      host.generateResponseError = failure;
      await expectLater(askStructured(model), throwsA(same(failure)));
    });

    group('ended under the reply', () {
      late PendingStructuredHost pending;

      setUp(() => install(pending = PendingStructuredHost()));

      Future<(InferenceModel, InferenceModelSession)> running() async {
        final model = await macModel();
        final session = await model.openSession(responseFormat: _codeFormat);
        await session.addQueryChunk(
          const Message(text: 'A poem', isUser: true),
        );
        return (model, session);
      }

      Future<void> untilSent() async {
        while (pending.pending == null) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      test('stopGeneration: stopped, at the model', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final reply = session.getResponse();
        await untilSent();

        await session.stopGeneration();

        await expectLater(
          reply,
          throwsA(
            isA<IncompleteStructuredOutputException>().having(
              (e) => e.end,
              'end',
              TurnEnd.stopped,
            ),
          ),
        );
        expect(pending.calls, contains('stopGeneration'));
      });

      test('a value that arrives after the stop is still stopped', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final reply = expectLater(
          session.getResponse(),
          throwsA(
            isA<IncompleteStructuredOutputException>().having(
              (e) => e.end,
              'end',
              TurnEnd.stopped,
            ),
          ),
        );
        await untilSent();
        // The OS answers while the stop is still under way.
        pending.stopGate = Completer<void>();
        final stopped = session.stopGeneration();
        pending.pending!.complete(_codeReply);
        await pumpEventQueue();
        pending.stopGate!.complete();
        await stopped;

        await reply;
      });

      test('a cancelled subscription stops the model', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final subscription = session.getResponseAsync().listen((_) {});
        await untilSent();

        await subscription.cancel();

        expect(pending.calls, contains('stopGeneration'));
        // The next turn runs.
        await session.addQueryChunk(const Message(text: 'Again', isUser: true));
        final next = session.getResponse();
        while (pending.pending!.isCompleted) {
          await Future<void>.delayed(Duration.zero);
        }
        pending.pending!.complete(_codeReply);
        expect(await next, _codeReply);
      });

      // Core's wrapper stops on a cancel too; the engine's own turn must,
      // whoever listens to it.
      test('a cancelled engine turn stops the model on its own', () async {
        final (model, _) = await running();
        final engine =
            (model.sessions.single as dynamic).engineSession
                as InferenceModelSession;
        final subscription = engine.getResponseAsync().listen((_) {});
        await untilSent();

        await subscription.cancel();

        expect(pending.calls, contains('stopGeneration'));
      });

      test('the session closed: closed', () async {
        final (_, session) = await running();
        final reply = session.getResponse();
        await untilSent();

        await session.close();

        await expectLater(
          reply,
          throwsA(
            isA<IncompleteStructuredOutputException>().having(
              (e) => e.end,
              'end',
              TurnEnd.closed,
            ),
          ),
        );
      });

      test('the model closed: closed', () async {
        final (model, session) = await running();
        final reply = session.getResponse();
        await untilSent();

        await model.close();

        await expectLater(
          reply,
          throwsA(
            isA<IncompleteStructuredOutputException>().having(
              (e) => e.end,
              'end',
              TurnEnd.closed,
            ),
          ),
        );
      });
    });
  });

  test('a structured chat answers with the value', () async {
    final model = await macModel();
    host.response = _codeReply;
    final chat = await model.openChat(responseFormat: _codeFormat);
    addTearDown(chat.close);
    await chat.addQueryChunk(const Message(text: 'A poem', isUser: true));

    final response = await chat.generateChatResponse();

    expect((response as TextResponse).token, _codeReply);
    expect(host.calls, contains('generateStructuredResponse'));
  });

  // B82: flutter_local_ai throws synchronously on a closed session.
  group('a closed session fails asynchronously', () {
    Future<BuiltInAiSession> closedSession() async {
      final model = await macModel();
      final session = await model.openSession() as BuiltInAiSession;
      await session.close();
      return session;
    }

    test('getResponse', () async {
      final session = await closedSession();
      late Future<String> reply;
      expect(() => reply = session.getResponse(), returnsNormally);
      await expectLater(reply, throwsStateError);
    });

    test('getResponseAsync', () async {
      final session = await closedSession();
      late Stream<String> reply;
      expect(() => reply = session.getResponseAsync(), returnsNormally);
      await expectLater(reply, emitsError(isStateError));
    });

    test('a structured turn', () async {
      final model = await macModel();
      final session = await model.openSession(responseFormat: _codeFormat);
      // The engine session underneath, closed behind core's back.
      await (model.sessions.single as dynamic).engineSession.close();
      await expectLater(session.getResponse(), throwsStateError);
    });
  });
}
