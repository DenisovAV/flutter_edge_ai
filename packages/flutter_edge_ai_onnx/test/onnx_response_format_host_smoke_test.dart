// Host smoke test for response formats (PR 9c) — REAL ORT-GenAI guidance
// through the real `dart:ffi` worker: a guided session's replies are values
// of its schema where the same prompt unguided is not one, on every turn; a
// turn cut at its cap is incomplete and the next one is a value again; the
// whole dialect compiles; and a prompt longer than the context window ends
// `contextLimit`.
//
// Skips cleanly unless the libraries and a model are available locally:
//   FLUTTER_GEMMA_ORT_GENAI_LIBS=/dir/with/libonnxruntime+libonnxruntime-genai
//   ONNX_SMOKE_GENAI_MODEL_DIR=/dir/with/genai_config.json+tokenizer.json
// (Phi-3.5-mini cpu-int4 is what it was written against.)
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _context = 512;

final _poem = ResponseFormat.jsonSchema({
  'type': 'object',
  'properties': {
    'title': {'type': 'string', 'minLength': 1, 'maxLength': 40},
    'lines': {
      'type': 'array',
      'items': {'type': 'string', 'maxLength': 80},
      'minItems': 2,
      'maxItems': 2,
    },
    'mood': {
      'enum': ['calm', 'stormy'],
    },
    'syllables': {'type': 'integer', 'minimum': 1, 'maximum': 99},
  },
  'required': ['title', 'lines', 'mood', 'syllables'],
  'additionalProperties': false,
});

/// Every keyword of the dialect at least once.
final _dialect = ResponseFormat.jsonSchema({
  'type': 'object',
  'title': 'Every keyword',
  'description': 'A record that uses each dialect keyword.',
  'properties': {
    'kind': {'const': 'record'},
    'level': {
      'enum': [1, 2, 3],
    },
    'score': {'type': 'number', 'minimum': 0, 'maximum': 1},
    'ok': {'type': 'boolean'},
    'note': {'type': 'null'},
    'tags': {
      'type': 'array',
      'items': {'type': 'string', 'minLength': 1, 'maxLength': 12},
      'minItems': 1,
      'maxItems': 3,
    },
    'origin': {
      'type': 'object',
      'properties': {
        'x': {'type': 'integer', 'minimum': -5, 'maximum': 5},
      },
      'required': ['x'],
      'additionalProperties': false,
      'examples': [
        {'x': 0},
      ],
    },
  },
  'required': ['kind', 'level', 'score', 'ok', 'note', 'tags', 'origin'],
  'additionalProperties': false,
});

const _ask = 'Write a two-line poem about the sea.';

Future<String> _reply(InferenceModelSession session, String text) async {
  await session.addQueryChunk(Message(text: text, isUser: true));
  final sw = Stopwatch()..start();
  final String reply;
  try {
    reply = await session.getResponse();
  } on IncompleteStructuredOutputException catch (e) {
    // ignore: avoid_print
    print('[format smoke] incomplete (${e.end}): ${jsonEncode(e.partialText)}');
    rethrow;
  }
  final m = session.getSessionMetrics();
  // ignore: avoid_print
  print(
    '[format smoke] ${sw.elapsedMilliseconds} ms, ${m.outputTokens} tokens, '
    '${m.tokensPerSecond?.toStringAsFixed(1)} tok/s: $reply',
  );
  return reply;
}

void main() {
  final libsDir = Platform.environment[genAiLibsDirEnvVar];
  final modelDir = Platform.environment['ONNX_SMOKE_GENAI_MODEL_DIR'];
  final available =
      libsDir != null &&
      libsDir.isNotEmpty &&
      modelDir != null &&
      File('$modelDir/genai_config.json').existsSync() &&
      genAiArchiveHasGuidance(Abi.current());

  late GenAiFfiClient client;
  late OnnxInferenceModel model;

  setUpAll(() async {
    if (!available) return;
    client = GenAiFfiClient();
    await client.load(modelDir, contextWindow: _context);
    model = OnnxInferenceModel(
      client: client,
      maxTokens: _context,
      modelType: ModelType.phi,
      activeBackend: null,
      onClose: () {},
    );
  });
  tearDownAll(() async {
    if (available) await model.close();
  });

  test(
    'guided replies are values of the schema, turn after turn, where the '
    'same prompt unguided is not one',
    () async {
      expect(
        model.structuredOutputSupport.isSupported,
        isTrue,
        reason: model.structuredOutputSupport.reason,
      );

      final plain = await model.openSession(topK: 1, maxOutputTokens: 80);
      final unguided = await _reply(plain, _ask);
      await plain.close();
      // The control: Phi answers this in prose, so the schema is what makes
      // the guided reply JSON.
      expect(() => jsonDecode(unguided.trim()), throwsFormatException);

      final guided = await model.openSession(
        topK: 1,
        maxOutputTokens: 120,
        responseFormat: _poem,
      );
      for (final prompt in [_ask, 'Now one about a storm.']) {
        final value = jsonDecode(await _reply(guided, prompt)) as Map;
        expect(
          value.keys,
          unorderedEquals(['title', 'lines', 'mood', 'syllables']),
        );
        expect(value['lines'], hasLength(2));
        expect(['calm', 'stormy'], contains(value['mood']));
      }
      await guided.close();
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'a turn cut at its cap is incomplete; the next turn is a value again',
    () async {
      final session = await model.openSession(
        topK: 1,
        maxOutputTokens: 6,
        responseFormat: _poem,
      );
      await expectLater(
        _reply(session, _ask),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.outputLimit,
          ),
        ),
      );
      await session.close();

      // The same, then a turn with room: on a fresh generator, guided again.
      final roomy = await model.openSession(
        topK: 1,
        maxOutputTokens: 120,
        responseFormat: _poem,
      );
      expect(jsonDecode(await _reply(roomy, _ask)), isA<Map>());
      await roomy.close();
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'every dialect keyword compiles and is held',
    () async {
      final session = await model.openSession(
        topK: 1,
        maxOutputTokens: 160,
        responseFormat: _dialect,
      );
      final value =
          jsonDecode(await _reply(session, 'Describe a small sample record.'))
              as Map;
      expect(value['kind'], 'record');
      expect([1, 2, 3], contains(value['level']));
      expect(value['note'], isNull);
      expect((value['origin'] as Map)['x'], inInclusiveRange(-5, 5));
      await session.close();
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'a prompt longer than the context window ends contextLimit',
    () async {
      final started = startGenAiTurn(
        client,
        GenAiTurn(
          userContent: List.filled(400, 'ocean wave').join(' '),
          sessionId: 999,
          isFirstTurn: true,
        ),
        guidance: genAiGuidanceSchema(_poem as JsonSchemaResponseFormat),
      );
      await expectLater(
        started.text.join(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not fit the context window'),
          ),
        ),
      );
      expect(await started.end, TurnEnd.contextLimit);
      await client.resetSession(sessionId: 999);
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
