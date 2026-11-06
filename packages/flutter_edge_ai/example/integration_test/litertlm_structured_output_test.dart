// LiteRT-LM LLGuidance through core's responseFormat API. This suite is
// deliberately discriminating: the unconstrained control must not satisfy the
// enum schema, while every structured turn must. It also exercises the turn
// ends and conversation recovery that can silently lose a constraint.
//
// The model is read directly from ~/models; FileSource registers that path and
// does not copy it into the app container. Run one backend at a time:
//   flutter test integration_test/litertlm_structured_output_test.dart -d macos
//   flutter test integration_test/litertlm_structured_output_test.dart -d macos \
//     --dart-define=STRUCTURED_BACKEND=gpu

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelFile = 'gemma-4-E2B-it.litertlm';
const _backendName = String.fromEnvironment(
  'STRUCTURED_BACKEND',
  defaultValue: 'cpu',
);
final _backend = PreferredBackend.values.byName(_backendName);

const _codeSchema = {
  'type': 'object',
  'properties': {
    'code': {
      'type': 'string',
      'enum': ['qzx-7', 'vlo-3'],
    },
  },
  'required': ['code'],
  'additionalProperties': false,
};
const _poem = 'Write a short poem about the sea. Do not output JSON.';
const _throughputPrompt =
    'Repeat the word ocean separated by spaces for at least five hundred '
    'words. Do not stop early.';
const _throughputSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string', 'minLength': 2000},
  },
  'required': ['text'],
  'additionalProperties': false,
};

bool _isCode(String text) {
  try {
    final value = jsonDecode(text) as Map<String, Object?>;
    return const ['qzx-7', 'vlo-3'].contains(value['code']);
  } catch (_) {
    return false;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  InferenceModel? model;

  Future<InferenceModel> ensureModel() async {
    if (model != null) return model!;
    final path =
        const String.fromEnvironment('LITERTLM_STRUCTURED_MODEL').isEmpty
        ? '${Platform.environment['HOME']}/models/$_modelFile'
        : const String.fromEnvironment('LITERTLM_STRUCTURED_MODEL');
    expect(File(path).existsSync(), isTrue, reason: 'model not found: $path');
    FlutterEdgeAi.reset();
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(backendFallback: false)],
    );
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(path).install();
    final loaded = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: _backend,
    );
    expect(loaded.activeBackend, _backend);
    expect(loaded.structuredOutputSupport.isSupported, isTrue);
    debugPrint(
      '[litertlm structured] support: ${loaded.structuredOutputSupport}',
    );
    return model = loaded;
  }

  Future<String> ask(
    InferenceModel m,
    String prompt, {
    ResponseFormat? format,
    int? maxOutputTokens,
  }) async {
    final session = await m.openSession(
      topK: 1,
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

  tearDownAll(() async {
    await model?.close();
    FlutterEdgeAi.reset();
  });

  test('discriminating enum versus an unconstrained control', () async {
    final m = await ensureModel();
    final control = await ask(m, _poem);
    debugPrint('[litertlm structured] control: ${jsonEncode(control)}');
    expect(_isCode(control), isFalse);

    final constrained = await ask(
      m,
      _poem,
      format: ResponseFormat.jsonSchema(_codeSchema),
    );
    debugPrint('[litertlm structured] constrained: $constrained');
    expect(_isCode(constrained), isTrue);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('multi-turn structured chat and an interleaved plain session', () async {
    final m = await ensureModel();
    final chat = await m.openChat(
      topK: 1,
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    final plain = await m.openSession(topK: 1);
    try {
      for (final prompt in [_poem, 'Choose the other allowed code.']) {
        await chat.addQueryChunk(Message(text: prompt, isUser: true));
        final response = await chat.generateChatResponse();
        expect(response, isA<TextResponse>());
        expect(_isCode((response as TextResponse).token), isTrue);

        await plain.addQueryChunk(
          const Message(text: 'Say hello in one word.', isUser: true),
        );
        final plainText = await plain.getResponse();
        expect(plainText.trim(), isNotEmpty);
        expect(_isCode(plainText), isFalse);
      }
    } finally {
      await chat.close();
      await plain.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a stopped structured turn recovers with its constraint', () async {
    final m = await ensureModel();
    final session = await m.openSession(
      topK: 1,
      responseFormat: ResponseFormat.jsonSchema({
        'type': 'object',
        'properties': {
          'story': {'type': 'string', 'minLength': 2000},
        },
        'required': ['story'],
        'additionalProperties': false,
      }),
    );
    try {
      await session.addQueryChunk(
        const Message(text: 'Write a very long dragon story.', isUser: true),
      );
      final turn = session.getResponse();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await session.stopGeneration();
      await expectLater(
        turn,
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.stopped,
          ),
        ),
      );

      await session.addQueryChunk(
        const Message(text: 'Write another long dragon story.', isUser: true),
      );
      final next = session.getResponse();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await session.stopGeneration();
      await expectLater(
        next,
        throwsA(isA<IncompleteStructuredOutputException>()),
      );
    } finally {
      await session.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('an output cap is reported instead of returning partial JSON', () async {
    final m = await ensureModel();
    await expectLater(
      ask(
        m,
        'Write a long dragon story.',
        maxOutputTokens: 4,
        format: ResponseFormat.jsonSchema({
          'type': 'object',
          'properties': {
            'story': {'type': 'string', 'minLength': 200},
          },
          'required': ['story'],
        }),
      ),
      throwsA(
        isA<IncompleteStructuredOutputException>().having(
          (e) => e.end,
          'end',
          TurnEnd.outputLimit,
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an input beyond the context is refused as a context limit', () async {
    final m = await ensureModel();
    final session = await m.openSession(
      topK: 1,
      responseFormat: ResponseFormat.jsonSchema(_codeSchema),
    );
    try {
      await session.addQueryChunk(
        Message(
          text: List.filled(3000, 'wide deep sea').join(' '),
          isUser: true,
        ),
      );
      await expectLater(
        session.getResponse(),
        throwsA(isA<ContextLimitException>()),
      );
      await session.addQueryChunk(const Message(text: _poem, isUser: true));
      expect(_isCode(await session.getResponse()), isTrue);
    } finally {
      await session.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an LLGuidance schema refusal closes only that session', () async {
    final m = await ensureModel();
    final session = await m.openSession(
      topK: 1,
      responseFormat: ResponseFormat.jsonSchema({'type': 'string', 'const': 7}),
    );
    await session.addQueryChunk(
      const Message(text: 'Return the required value.', isUser: true),
    );
    await expectLater(
      session.getResponse(),
      throwsA(isA<ResponseFormatUnsupportedException>()),
    );
    await expectLater(
      session.addQueryChunk(const Message(text: 'Try again.', isUser: true)),
      throwsStateError,
    );

    expect(
      _isCode(
        await ask(m, _poem, format: ResponseFormat.jsonSchema(_codeSchema)),
      ),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'reports comparable median tok/s with and without a constraint',
    () async {
      final m = await ensureModel();

      Future<({int tokens, double tokensPerSecond})> measure(
        ResponseFormat? format,
      ) async {
        final session = await m.openSession(
          topK: 1,
          maxOutputTokens: 64,
          responseFormat: format,
        );
        try {
          await session.addQueryChunk(
            const Message(text: _throughputPrompt, isUser: true),
          );
          try {
            await session.getResponse();
          } on IncompleteStructuredOutputException catch (error) {
            expect(format, isNotNull);
            expect(error.end, TurnEnd.outputLimit);
          }
          final metrics = session.getSessionMetrics();
          final speed = metrics.tokensPerSecond;
          expect(speed, isNotNull);
          expect(metrics.outputTokens, greaterThanOrEqualTo(60));
          return (tokens: metrics.outputTokens, tokensPerSecond: speed!);
        } finally {
          await session.close();
        }
      }

      final constrainedFormat = ResponseFormat.jsonSchema(_throughputSchema);

      // Exclude one warm-up turn in each mode, then alternate order so neither
      // median consistently benefits from being the second run in a pair.
      await measure(null);
      await measure(constrainedFormat);
      final plain = <({int tokens, double tokensPerSecond})>[];
      final constrained = <({int tokens, double tokensPerSecond})>[];
      for (var i = 0; i < 5; i++) {
        if (i.isEven) {
          plain.add(await measure(null));
          constrained.add(await measure(constrainedFormat));
        } else {
          constrained.add(await measure(constrainedFormat));
          plain.add(await measure(null));
        }
      }

      for (var i = 0; i < plain.length; i++) {
        expect(
          (plain[i].tokens - constrained[i].tokens).abs(),
          lessThanOrEqualTo(1),
          reason:
              'plain and constrained runs must measure the same token count',
        );
      }
      double median(List<({int tokens, double tokensPerSecond})> samples) {
        final values = samples.map((sample) => sample.tokensPerSecond).toList()
          ..sort();
        return values[values.length ~/ 2];
      }

      debugPrint(
        '[litertlm structured] $_backendName median native decode tok/s '
        '(5 runs after per-mode warm-up): '
        'plain=${median(plain).toStringAsFixed(1)} '
        'tokens=${plain.map((sample) => sample.tokens).toList()}, '
        'constraint=${median(constrained).toStringAsFixed(1)} '
        'tokens=${constrained.map((sample) => sample.tokens).toList()}',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
