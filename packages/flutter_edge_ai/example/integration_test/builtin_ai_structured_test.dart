// Built-in AI with a response format, on a real OS model (Apple Foundation
// Models; macOS first). The discriminating test: a schema the model would not
// produce unprompted is checked unconstrained first (it must fail it), then
// constrained (it must pass). The rest pins what the platform does with each
// part of the keyword set the engine claims, and how a turn ends.
//
// Run, one at a time (Rule 6):
//   flutter test integration_test/builtin_ai_structured_test.dart -d macos
//
// Needs Apple Intelligence on and its model downloaded; otherwise every test
// is skipped. Passing here is what lets the platform be added to
// `_verifiedPlatforms` in flutter_edge_ai_builtin_ai's structured_output.dart.
// Nothing is in setUp (Rule 6b): each test calls ensureModel() first.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
// The run that enables a platform drives the path while it is still refused.
// ignore: implementation_imports — marks the running platform as verified, in this process only
import 'package:flutter_edge_ai_builtin_ai/src/structured_output.dart'
    show currentBuiltInPlatform, debugVerifiedBuiltInPlatforms;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _codeSchema = {
  'type': 'object',
  'properties': {
    'code': {
      'enum': ['qzx-7', 'vlo-3'],
    },
  },
  'required': ['code'],
};

const _poemPrompt = 'Write a short poem about the sea.';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  InferenceModel? model;
  String? unavailable;

  /// The active built-in model, or null (with [unavailable] set) when the OS
  /// model cannot run here.
  Future<InferenceModel?> ensureModel() async {
    if (model != null || unavailable != null) return model;
    debugVerifiedBuiltInPlatforms = {currentBuiltInPlatform()};
    await FlutterEdgeAi.initialize(inferenceEngines: const [BuiltInAiEngine()]);
    final status = await BuiltInAi.availability().timeout(
      const Duration(seconds: 45),
    );
    if (status != BuiltInAiAvailability.available) {
      unavailable = 'BuiltInAI is $status here';
      return null;
    }
    final spec = BuiltInAiModels.forCurrentPlatform!;
    await FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromBundled(spec.name).install();
    return model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
  }

  Future<String> ask(
    InferenceModel model,
    String prompt, {
    ResponseFormat? format,
    int? maxOutputTokens,
  }) async {
    final session = await model.openSession(
      responseFormat: format,
      maxOutputTokens: maxOutputTokens,
    );
    try {
      await session.addQueryChunk(Message(text: prompt, isUser: true));
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }

  test('the support it reports', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    debugPrint('[structured] support: ${m.structuredOutputSupport}');
    expect(m.structuredOutputSupport.isSupported, isTrue);
    expect(m.structuredOutputSupport.delivery, StructuredDelivery.buffered);
  });

  test(
    'unconstrained control: the poem is not a value of the schema',
    () async {
      final m = await ensureModel();
      if (m == null) return markTestSkipped(unavailable!);
      final reply = await ask(m, _poemPrompt);
      debugPrint('[structured] control: ${jsonEncode(reply)}');
      Object? decoded;
      try {
        decoded = jsonDecode(reply.trim());
      } on FormatException {
        decoded = null;
      }
      final conforms =
          decoded is Map && const ['qzx-7', 'vlo-3'].contains(decoded['code']);
      expect(conforms, isFalse);
    },
  );

  test(
    'constrained: the same prompt answers with a value of the schema',
    () async {
      final m = await ensureModel();
      if (m == null) return markTestSkipped(unavailable!);
      final reply = await ask(
        m,
        _poemPrompt,
        format: ResponseFormat.jsonSchema(_codeSchema),
      );
      debugPrint('[structured] constrained: ${jsonEncode(reply)}');
      final decoded = jsonDecode(reply) as Map<String, Object?>;
      expect(const ['qzx-7', 'vlo-3'], contains(decoded['code']));
    },
  );

  test('a streamed structured reply is one chunk', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final session = await m.openSession(
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    addTearDown(session.close);
    await session.addQueryChunk(const Message(text: _poemPrompt, isUser: true));
    final chunks = await session.getResponseAsync().toList();
    debugPrint('[structured] chunks: $chunks');
    expect(chunks, hasLength(1));
    jsonDecode(chunks.single);
  });

  test('nested objects, scalars, arrays and bounds', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final reply = await ask(
      m,
      'Describe a cat called Tom, aged 3, weight 4.5 kg, an indoor cat, '
      'with its favourite toys.',
      format: ResponseFormat.jsonSchema({
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'integer'},
          'weight': {'type': 'number'},
          'indoor': {'type': 'boolean'},
          'owner': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
            'required': ['city'],
          },
          'toys': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 2,
            'maxItems': 3,
          },
        },
        'required': ['name', 'age', 'weight', 'indoor', 'owner', 'toys'],
      }),
    );
    debugPrint('[structured] nested: $reply');
    final decoded = jsonDecode(reply) as Map<String, Object?>;
    expect((decoded['toys']! as List).length, inInclusiveRange(2, 3));
  });

  // What Apple makes of a property left out of `required`: omitted, or null
  // (which core's check would refuse as a non-string).
  test('a property that is not required', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final format = ResponseFormat.jsonSchema({
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'subtitle': {'type': 'string'},
      },
      'required': ['title'],
    });
    for (final prompt in [
      'Give a book title only. No subtitle.',
      'Give a book title and a subtitle.',
    ]) {
      try {
        final reply = await ask(m, prompt, format: format);
        debugPrint('[structured] optional ok: $reply');
      } on StructuredOutputException catch (e) {
        debugPrint('[structured] optional FAILED: $e');
        rethrow;
      }
    }
  });

  test('an array root', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final format = ResponseFormat.jsonSchema({
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 2,
      'maxItems': 4,
    });
    try {
      final reply = await ask(m, 'Name some colours.', format: format);
      debugPrint('[structured] array root: $reply');
    } catch (e) {
      debugPrint('[structured] array root FAILED: ${e.runtimeType} $e');
      rethrow;
    }
  });

  test('a string root', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    try {
      final reply = await ask(
        m,
        'Name a colour.',
        format: ResponseFormat.jsonSchema({'type': 'string'}),
      );
      debugPrint('[structured] string root: $reply');
    } catch (e) {
      debugPrint('[structured] string root FAILED: ${e.runtimeType} $e');
      rethrow;
    }
  });

  // Apple caps a reply with maximumResponseTokens and does not say when it
  // did, so a format with a cap is refused there before a session opens.
  test('maxOutputTokens with a format is refused on Apple', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    await expectLater(
      m.openSession(
        responseFormat: ResponseFormat.jsonSchema(_codeSchema),
        maxOutputTokens: 5,
      ),
      throwsA(isA<ResponseFormatUnsupportedException>()),
    );
  });

  // Whether FoundationModels keeps a prompt it refused as too long: if it
  // did, every later turn of the session would overflow too. Decides whether
  // built-in AI may report an overflow as a refused input (an error with
  // TurnEnd.contextLimit, design §3) on this platform.
  test('after an overflow, a short prompt on the same session', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final session = await m.openSession(
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    addTearDown(session.close);
    await session.addQueryChunk(
      Message(
        text: 'Summarise: ${'the sea is wide and deep. ' * 4000}',
        isUser: true,
      ),
    );
    try {
      await session.getResponse();
      debugPrint('[structured] overflow: the long prompt was answered');
    } catch (e) {
      debugPrint('[structured] overflow: ${e.runtimeType} $e');
    }
    await session.addQueryChunk(const Message(text: _poemPrompt, isUser: true));
    try {
      final next = await session.getResponse();
      debugPrint('[structured] after overflow, answered: $next');
    } catch (e) {
      debugPrint('[structured] after overflow, FAILED: ${e.runtimeType} $e');
      rethrow;
    }
  });

  test('a stop mid-reply ends the turn as stopped', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final session = await m.openSession(
      responseFormat: ResponseFormat.jsonSchema({
        'type': 'object',
        'properties': {
          'story': {'type': 'string'},
        },
        'required': ['story'],
      }),
    );
    addTearDown(session.close);
    await session.addQueryChunk(
      const Message(text: 'Write a long story about a dragon.', isUser: true),
    );
    final reply = session.getResponse();
    await Future<void>.delayed(const Duration(milliseconds: 300));
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
    // The session answers again after the stop.
    await session.addQueryChunk(
      const Message(text: 'A one-line story.', isUser: true),
    );
    final next = await session.getResponse();
    debugPrint('[structured] after stop: $next');
    jsonDecode(next);
  });

  test('structured and plain sessions alternate, three turns each', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final structured = await m.openSession(
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    final plain = await m.openSession();
    addTearDown(structured.close);
    addTearDown(plain.close);
    for (var turn = 0; turn < 3; turn++) {
      await structured.addQueryChunk(
        const Message(text: _poemPrompt, isUser: true),
      );
      final value = jsonDecode(await structured.getResponse()) as Map;
      expect(const ['qzx-7', 'vlo-3'], contains(value['code']));
      await plain.addQueryChunk(
        const Message(text: 'Say hello in one word.', isUser: true),
      );
      final text = await plain.getResponse();
      debugPrint('[structured] plain turn $turn: ${jsonEncode(text)}');
      expect(text.trim(), isNotEmpty);
    }
  });

  test('a structured chat, two turns', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    final chat = await m.openChat(
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    addTearDown(chat.close);
    for (final prompt in [_poemPrompt, 'Another one, please.']) {
      await chat.addQueryChunk(Message(text: prompt, isUser: true));
      final response = await chat.generateChatResponse();
      final text = (response as TextResponse).token;
      debugPrint('[structured] chat: $text');
      expect(const [
        'qzx-7',
        'vlo-3',
      ], contains((jsonDecode(text) as Map)['code']));
    }
  });

  test('refused before a session opens', () async {
    final m = await ensureModel();
    if (m == null) return markTestSkipped(unavailable!);
    expect(m.refusalFor(ResponseFormat.jsonObject()), isNotNull);
    await expectLater(
      m.openSession(
        responseFormat: ResponseFormat.jsonSchema({
          'type': 'object',
          'properties': {
            'n': {'type': 'integer', 'minimum': 1},
          },
        }),
      ),
      throwsA(
        isA<ResponseFormatUnsupportedException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/properties/n/minimum',
        ),
      ),
    );
  });
}
