// Host smoke test for response formats (PR 9c) — REAL ORT-GenAI guidance
// through the real `dart:ffi` worker: a guided session's replies are values
// of its schema where the same prompt unguided is not one, on every turn; a
// cut turn (stopped, or at its cap) is rewound exactly — the next turn is
// the same as with no cut turn at all; a context window filled during decode
// ends `contextLimit` and the session goes on with its history; the whole
// dialect compiles; and a prompt longer than the window ends a structured
// turn `contextLimit` and fails a plain one, leaving both conversations.
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
    // This test is the run that enables a host (`_verifiedGuidanceAbis`), so
    // it treats the host it runs on as enabled.
    debugVerifiedGuidanceAbis = {Abi.current()};
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

  /// One turn on [session]'s generator, through the client: per-turn caps,
  /// greedy. [stopAfterFirstChunk] stops it at its first chunk.
  Future<(String, TurnEnd)> turn(
    int session,
    String text, {
    bool fresh = false,
    int? cap,
    String? guidance,
    bool stopAfterFirstChunk = false,
  }) async {
    final started = startGenAiTurn(
      client,
      GenAiTurn(
        userContent: text,
        sessionId: session,
        isFirstTurn: fresh,
        maxOutputTokens: cap,
        searchOptions: const {'do_sample': false},
      ),
      guidance: guidance,
    );
    final out = StringBuffer();
    var stopping = false;
    await for (final piece in started.text) {
      out.write(piece);
      if (stopAfterFirstChunk && !stopping) {
        stopping = true;
        await client.stopGeneration(sessionId: session);
      }
    }
    final end = await started.end!;
    // ignore: avoid_print
    print('[format smoke] session $session -> $end ${jsonEncode('$out')}');
    return ('$out', end);
  }

  test(
    'a cut turn is rewound: the same generator keeps its history, and the '
    'next turn is the same as with no cut turn at all',
    () async {
      final guidance = genAiGuidanceSchema(_poem as JsonSchemaResponseFormat);
      const fact = 'My secret word is PINEAPPLE. Reply with OK only.';
      const question = 'What is my secret word? Answer with that word only.';

      // Unguided, stopped at its first chunk, against the same history
      // without that turn.
      await turn(100, fact, fresh: true, cap: 8);
      expect(
        (await turn(
          100,
          'Write a long story about the sea.',
          stopAfterFirstChunk: true,
        )).$2,
        TurnEnd.stopped,
      );
      final (afterStop, _) = await turn(100, question, cap: 12);
      await turn(101, fact, fresh: true, cap: 8);
      final (control, _) = await turn(101, question, cap: 12);
      expect(afterStop, control, reason: 'rewind after a stop is not exact');
      expect(afterStop.toLowerCase(), contains('pineapple'));

      // Guided, cut at its cap, against the same history without that turn:
      // also proves the grammar is reset (a reused, unrewound generator
      // fails the next prefill: "Error committing tokens").
      await turn(102, _ask, fresh: true, cap: 120, guidance: guidance);
      expect(
        (await turn(
          102,
          'Now one about a storm.',
          cap: 6,
          guidance: guidance,
        )).$2,
        TurnEnd.outputLimit,
      );
      final (afterCut, cutEnd) = await turn(
        102,
        'Now one about the moon.',
        cap: 120,
        guidance: guidance,
      );
      await turn(103, _ask, fresh: true, cap: 120, guidance: guidance);
      final (guidedControl, _) = await turn(
        103,
        'Now one about the moon.',
        cap: 120,
        guidance: guidance,
      );
      expect(cutEnd, TurnEnd.endOfSequence);
      expect(jsonDecode(afterCut), isA<Map>());
      expect(afterCut, guidedControl, reason: 'rewind after a cut not exact');
      for (final id in [100, 101, 102, 103]) {
        await client.resetSession(sessionId: id);
      }
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'a context window filled during decode ends contextLimit; the session '
    'keeps its history and goes on',
    () async {
      // The first turn takes most of the window, so the second cannot end
      // before max_length.
      var filler = 'ocean wave';
      while (await client.countTokens(filler) < _context - 140) {
        filler = '$filler ocean wave';
      }
      await turn(
        110,
        'My secret word is CACTUS. Ignore this text: $filler. Reply with OK '
        'only.',
        fresh: true,
        cap: 8,
      );
      final (_, end) = await turn(
        110,
        'Write a story about the sea, at least three hundred words long.',
      );
      expect(end, TurnEnd.contextLimit);
      final (answer, answerEnd) = await turn(
        110,
        'What is my secret word? Answer with that word only.',
        cap: 12,
      );
      expect(answerEnd, isNot(TurnEnd.contextLimit));
      expect(answer.toLowerCase(), contains('cactus'));
      await client.resetSession(sessionId: 110);
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'a guided session cut at its cap is incomplete; its next turn is a value',
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
    'a prompt longer than the context window: a structured session ends it '
    'contextLimit, a plain one fails it; both keep the conversation',
    () async {
      final long = List.filled(400, 'ocean wave').join(' ');
      final guided = await model.openSession(
        topK: 1,
        maxOutputTokens: 120,
        responseFormat: _poem,
      );
      await expectLater(
        _reply(guided, long),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.contextLimit,
          ),
        ),
      );
      expect(jsonDecode(await _reply(guided, _ask)), isA<Map>());
      await guided.close();

      final plain = await model.openSession(topK: 1, maxOutputTokens: 12);
      await _reply(plain, 'My secret word is CACTUS. Reply with OK only.');
      await expectLater(
        _reply(plain, long),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not fit the context window'),
          ),
        ),
      );
      final answer = await _reply(
        plain,
        'What is my secret word? Answer with that word only.',
      );
      expect(answer.toLowerCase(), contains('cactus'));
      await plain.close();
    },
    skip: available ? false : 'needs ORT-GenAI libs and a model',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
