// A response format on built-in AI: which platforms take one, which schemas
// are refused before a session opens, what reaches flutter_local_ai, and how
// each structured turn ends. Driven through core's openSession/openChat, so
// core's checks run over the engine's answers as they do in an app.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show PlatformException;
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

      Matcher endedAs(TurnEnd end) => throwsA(
        isA<IncompleteStructuredOutputException>().having(
          (e) => e.end,
          'end',
          end,
        ),
      );

      test('stopGeneration: stopped once the call has settled', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        var settled = false;
        final reply = session.getResponse().whenComplete(() => settled = true);
        final check = expectLater(reply, endedAs(TurnEnd.stopped));
        await untilSent();

        await session.stopGeneration();
        await pumpEventQueue();

        // The platform call is still running: the turn has not ended, so no
        // next turn can meet a busy session.
        expect(settled, isFalse);
        expect(pending.stops, 1);
        pending.settleStopped();
        await check;
      });

      test('a value that arrives after the stop is still stopped', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final check = expectLater(
          session.getResponse(),
          endedAs(TurnEnd.stopped),
        );
        await untilSent();

        await session.stopGeneration();
        pending.pending!.complete(_codeReply);

        await check;
      });

      test(
        'the next turn starts only after the stopped call settled',
        () async {
          final (_, session) = await running();
          addTearDown(session.close);
          final first = expectLater(
            session.getResponse(),
            endedAs(TurnEnd.stopped),
          );
          await untilSent();
          final stoppedCall = pending.pending!;
          await session.stopGeneration();
          await session.addQueryChunk(
            const Message(text: 'Again', isUser: true),
          );
          final next = session.getResponse();
          await pumpEventQueue();
          expect(identical(pending.pending, stoppedCall), isTrue);

          pending.settleStopped();
          await first;
          while (identical(pending.pending, stoppedCall)) {
            await Future<void>.delayed(Duration.zero);
          }
          pending.pending!.complete(_codeReply);
          expect(await next, _codeReply);
        },
      );

      test('a cancelled subscription stops the model once', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final subscription = session.getResponseAsync().listen((_) {});
        await untilSent();
        final cancelled = subscription.cancel();
        await pumpEventQueue();
        pending.settleStopped();
        await cancelled;

        // The engine's cancel and core's stop: one reaches the model.
        expect(pending.stops, 1);
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

        expect(pending.stops, 1);
      });

      test(
        'a stop that fails during a cancel does not hang the session',
        () async {
          final (_, session) = await running();
          addTearDown(session.close);
          pending.stopError = PlatformException(code: 'channel-error');
          final subscription = session.getResponseAsync().listen((_) {});
          await untilSent();
          final stoppedCall = pending.pending!;

          final cancelled = subscription.cancel();
          await pumpEventQueue();
          stoppedCall.complete('');
          await cancelled;

          pending.stopError = null;
          await session.addQueryChunk(
            const Message(text: 'Again', isUser: true),
          );
          final next = session.getResponse();
          while (identical(pending.pending, stoppedCall)) {
            await Future<void>.delayed(Duration.zero);
          }
          pending.pending!.complete(_codeReply);
          expect(await next, _codeReply);
        },
      );

      test('the session closed: closed, after the native close', () async {
        final (_, session) = await running();
        final check = expectLater(
          session.getResponse(),
          endedAs(TurnEnd.closed),
        );
        await untilSent();

        await session.close();

        await check;
        expect(pending.closedIds, isNotEmpty);
      });

      test('a failed close leaves the turn running', () async {
        final (_, session) = await running();
        addTearDown(session.close);
        final reply = session.getResponse();
        await untilSent();
        pending.closeSessionError = StateError('teardown failed');

        await expectLater(session.close(), throwsStateError);
        pending.closeSessionError = null;
        // The session is still open, so its answer is the turn's.
        pending.pending!.complete(_codeReply);

        expect(await reply, _codeReply);
      });

      for (final closer in ['session', 'model']) {
        test(
          'the OS fails the call while the $closer closes: closed',
          () async {
            final (model, session) = await running();
            pending.failCallOnClose = true;
            final check = expectLater(
              session.getResponse(),
              endedAs(TurnEnd.closed),
            );
            await untilSent();

            await (closer == 'model' ? model.close() : session.close());

            await check;
          },
        );
      }

      test('the model closed: closed', () async {
        final (model, session) = await running();
        final check = expectLater(
          session.getResponse(),
          endedAs(TurnEnd.closed),
        );
        await untilSent();

        await model.close();

        await check;
      });
    });
  });

  group('platform errors', () {
    // Windows cannot drop the overflowing prompt from its transcript, so the
    // session would fail every later turn: not the usable session
    // contextLimit promises.
    test('Windows PROMPT_TOO_LONG ends the turn as closed', () async {
      final model = await macModel();
      host.generateResponseError = PlatformException(
        code: 'PROMPT_TOO_LONG',
        message:
            'The conversation no longer fits the Windows AI context window.',
      );
      await expectLater(
        askStructured(model),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.closed,
          ),
        ),
      );
    });

    test(
      'Windows STRUCTURED_OUTPUT_INVALID is core\'s non-conforming reply',
      () async {
        final model = await macModel();
        host.generateResponseError = PlatformException(
          code: 'STRUCTURED_OUTPUT_INVALID',
          message:
              'Windows AI produced output that does not conform to the schema.',
          details: '{"code":"nope"}',
        );
        await expectLater(
          askStructured(model),
          throwsA(
            isA<NonConformingStructuredOutputException>().having(
              (e) => e.text,
              'text',
              '{"code":"nope"}',
            ),
          ),
        );
      },
    );

    // Chrome rethrows the Prompt API's own JS error (QuotaExceededError on an
    // overflow); this package does not read JS errors, so it stays the error
    // it is rather than a guessed contextLimit.
    test(
      'an error the engine cannot classify is passed on unchanged',
      () async {
        final model = await macModel();
        final failure = PlatformException(code: 'GENERATION_BLOCKED');
        host.generateResponseError = failure;
        await expectLater(askStructured(model), throwsA(same(failure)));
      },
    );
  });

  group('maxOutputTokens with a format', () {
    test('refused on iOS too', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      debugVerifiedBuiltInPlatforms = {BuiltInPlatform.appleIos};
      final model = await const BuiltInAiEngine().createModel(
        builtInSpec(),
        builtInConfig,
      );
      addTearDown(model.close);
      expect(model.refusalFor(_codeFormat), isNull);
      await expectLater(
        model.openSession(responseFormat: _codeFormat, maxOutputTokens: 64),
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
      expect(model.sessions, isEmpty);
    });

    test('refused on Apple before a session opens', () async {
      final model = await macModel();
      host.calls.clear();
      await expectLater(
        model.openSession(responseFormat: _codeFormat, maxOutputTokens: 64),
        throwsA(
          isA<ResponseFormatUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('maxOutputTokens'),
          ),
        ),
      );
      expect(host.calls, isNot(contains('createSession')));
      expect(model.sessions, isEmpty);
    });

    test('accepted where no cap applies (Windows)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugVerifiedBuiltInPlatforms = {BuiltInPlatform.windows};
      final model = await const BuiltInAiEngine().createModel(
        builtInSpec(),
        builtInConfig,
      );
      addTearDown(model.close);
      final session = await model.openSession(
        responseFormat: _codeFormat,
        maxOutputTokens: 64,
      );
      await session.close();
    });

    test('a plain Apple session keeps its cap', () async {
      final model = await macModel();
      final session = await model.openSession(maxOutputTokens: 64);
      await session.close();
    });
  });

  test('a whole-number minItems/maxItems is sent as an int', () async {
    final model = await macModel();
    host.response = '{"tags":["a","b"]}';
    final format = ResponseFormat.jsonSchema({
      'type': 'object',
      'properties': {
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 2.0,
          'maxItems': 3.0,
        },
      },
      'required': ['tags'],
    });
    final session = await model.openSession(responseFormat: format);
    addTearDown(session.close);
    await session.addQueryChunk(const Message(text: 'Tags', isUser: true));

    expect(await session.getResponse(), '{"tags":["a","b"]}');
    final sent = host.sessions.single.lastSchemaJson!;
    expect(sent, contains('"minItems":2,'));
    expect(sent, contains('"maxItems":3}'));
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
