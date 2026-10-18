// InferenceModel.createDecider on LiteRT-LM (option scoring), on real models:
// litetune's golden packs, each a decision-tuned .litertlm whose
// `litetune.decision` section the decider reads, with the golden.json litetune
// measured it with (for every held-out row and option: the engine's scores on
// its server CPU, the PyTorch float32 reference and a float32 twin's).
//
// The packs are private, so they are not in the repository. Stage each in a
// directory of its own holding `model.litertlm` and `golden.json`:
//   macOS: <the example's container Documents>/decisions/<pack>/
// or name the parent with --dart-define=DECIDER_PACKS=<dir>. A float32 twin
// of a pack's model, staged beside it as `twin.litertlm`, is checked against
// the reference to 1e-3 nats per token: the method alone, with no
// quantisation in between. The refusal tests also need FunctionGemma 270M
// (`functiongemma-270M-it.litertlm`) in the container Documents: a real chat
// model without a decision section.
//
// What is asserted per row, on this machine: the rendered prompt and its
// token ids are the golden ones; the decider's top option is the reference's;
// its answer follows the section's rule on its own scores, and is the golden
// answer unless the golden top probability is within 0.05 of the threshold
// (another CPU's int8 kernels move a probability that close across it);
// every token is within 2.0 nats of the reference. The gap to the golden
// engine scores is printed, not asserted: it measures this CPU's int8
// arithmetic against the one litetune ran on.
//
// Run (CPU; one model at a time):
//   flutter test integration_test/litertlm_inference_decider_test.dart -d macos
// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _packsDefine = String.fromEnvironment('DECIDER_PACKS');

String get _documents =>
    '${Platform.environment['HOME']}/Library/Containers/'
    'dev.flutterberlin.flutterGemmaExample55/Data/Documents';

Directory get _packsDir =>
    Directory(_packsDefine.isNotEmpty ? _packsDefine : '$_documents/decisions');

/// A per-token bound that holds on both CPUs measured: 1.4272 nats on
/// litetune's Xeon, 1.8833 on an Apple M-series (2026-10-18). Wrong scoring
/// (the other #3561 mode) is 8.75 nats off.
const _referenceBound = 2.0;

/// A golden answer whose top probability is this close to the threshold may
/// fall on the other side on another CPU.
const _borderline = 0.05;

/// The decision contract's user message (`decisions.Decision.render`), from
/// the section payload: the check that the golden prompts are the contract's.
String _render(Map<String, Object?> payload, String state) {
  final lines = [
    for (final o in (payload['options'] as List).cast<Map<String, Object?>>())
      o['description'] == null
          ? '- ${o['id']}'
          : '- ${o['id']}: ${o['description']}',
    if (payload['none_option'] case final String none) '- $none',
  ];
  return '$state\n\nQuestion: ${payload['question']}\nOptions:\n'
      '${lines.join('\n')}\nAnswer with the id of one option.';
}

List<DeciderOption> _options(Map<String, Object?> payload) => [
  for (final o in (payload['options'] as List).cast<Map<String, Object?>>())
    DeciderOption(o['id'] as String, description: o['description'] as String?),
  if (payload['none_option'] case final String none) DeciderOption(none),
];

InferenceDeciderCalibration _calibration(Map<String, Object?> payload) {
  final below = (payload['abstain_below'] as num?)?.toDouble();
  return InferenceDeciderCalibration(
    temperature: (payload['temperature'] as num).toDouble(),
    abstainBelow: below == null || below == 0 ? null : below,
    noneOption: payload['none_option'] as String?,
  );
}

/// The model [_load] built last; closed at the end.
InferenceModel? _active;

Future<InferenceModel> _load(
  String path, {
  PreferredBackend backend = PreferredBackend.cpu,
  ModelType modelType = ModelType.gemmaIt,
}) async {
  await FlutterEdgeAi.installModel(
    modelType: modelType,
    fileType: ModelFileType.litertlm,
  ).fromFile(path).install();
  return _active = await FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: backend,
  );
}

List<Directory> _packs() {
  final dir = _packsDir;
  if (!dir.existsSync()) return const [];
  return [
    for (final entry
        in dir.listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (entry is Directory &&
          File('${entry.path}/golden.json').existsSync() &&
          File('${entry.path}/model.litertlm').existsSync())
        entry,
  ];
}

String _name(Directory pack) => pack.path.split('/').last;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final packs = _packs();

  setUpAll(registerTestEngines);
  tearDownAll(() async => _active?.close());

  test('golden packs are staged', () {
    expect(
      packs,
      isNotEmpty,
      reason:
          'no pack with model.litertlm and golden.json in ${_packsDir.path}',
    );
    // ignore: avoid_print
    print('[decider] packs: ${packs.map(_name).toList()}');
  });

  for (final pack in packs) {
    test('${_name(pack)}: every golden row on the real model', () async {
      final golden =
          jsonDecode(File('${pack.path}/golden.json').readAsStringSync())
              as Map<String, Object?>;
      final provenance = golden['provenance'] as Map<String, Object?>;
      final section = provenance['section'] as Map<String, Object?>;
      final payload = section['payload'] as Map<String, Object?>;
      final type = payload['type'] as String;
      final model = await _load('${pack.path}/model.litertlm');
      final engine = model as OptionScoringModel;

      // The section, exactly as the file carries it.
      final read = await engine.readDecisionSection();
      expect(read, section['payload_text']);
      expect(jsonDecode(read!), payload);

      final listed = [
        for (final o in (payload['options'] as List).cast<Map>())
          o['id'] as String,
        if (payload['none_option'] case final String none) none,
      ];
      final terminator = payload['terminator'] as String;
      final scoredLengths = (payload['scored_lengths'] as List).cast<int>();
      final temperature = (payload['temperature'] as num).toDouble();
      final below = (payload['abstain_below'] as num?)?.toDouble();

      final created = Stopwatch()..start();
      final decider = await model.createDecider(
        question: payload['question'] as String,
        options: _options(payload),
        calibration: _calibration(payload),
      );
      created.stop();
      final mode = ((decider as dynamic).mode as Enum).name;
      // ignore: avoid_print
      print(
        '[decider] ${_name(pack)}: $type, ${listed.length} options, '
        'created in ${created.elapsedMilliseconds} ms, mode $mode '
        '(golden ${provenance['mode']})',
      );
      expect(mode, provenance['mode']);

      final scorer = await engine.openOptionScorer();
      final fullTargets = [for (final id in listed) '$id$terminator'];
      var maxToReference = 0.0;
      var maxToGoldenEngine = 0.0;
      var maxTopToReference = 0.0;
      var maxPrefixVsFull = 0.0;
      var argmaxAgree = 0;
      var answerAgree = 0;
      final borderline = <String>[];
      final times = <int>[];
      final rows = (golden['rows'] as List).cast<Map<String, Object?>>();
      for (final row in rows) {
        final index = row['index'];
        final state = row['state'] as String;
        final userMessage = _render(payload, state);
        expect(userMessage, row['user_message'], reason: 'row $index');

        // The prompt the engine renders, as its tokens.
        final rendered = await scorer.renderUserMessage(userMessage);
        final ids = await scorer.tokenize(rendered);
        expect(ids, row['engine_prompt_ids'], reason: 'row $index');
        expect(ids.length + 1, row['prompt_tokens_with_bos']);
        final last = await scorer.detokenize([ids.last]);

        // Every token of every option's full target, as the reference has
        // them, by the mode the self-check picked.
        final full = await scorer.score(
          rendered,
          fullTargets,
          reprefill: mode == 'once' ? last : null,
        );
        final options = (row['options'] as List).cast<Map<String, Object?>>();
        final prefixSums = <double>[];
        for (var j = 0; j < listed.length; j++) {
          final ref = (options[j]['reference_token_scores'] as List)
              .cast<num>();
          final eng = (options[j]['engine_token_scores'] as List).cast<num>();
          final mine = full.tokenScores[j];
          expect(mine.length, ref.length, reason: 'row $index ${listed[j]}');
          for (var i = 0; i < mine.length; i++) {
            maxToReference = math.max(maxToReference, (mine[i] - ref[i]).abs());
          }
          for (var i = 0; i < eng.length; i++) {
            maxToGoldenEngine = math.max(
              maxToGoldenEngine,
              (mine[i] - eng[i]).abs(),
            );
          }
          prefixSums.add(
            mine.take(scoredLengths[j]).fold(0.0, (a, s) => a + s),
          );
        }

        // The decider's own answer.
        final watch = Stopwatch()..start();
        final answer = await decider.choose(
          DeciderInput(EmbeddingInput.text(state)),
          topK: listed.length,
        );
        times.add(watch.elapsedMilliseconds);
        final p = answer.probabilities!;

        // Its scores are the full targets' first scored_lengths tokens:
        // a unique prefix scores as the same tokens of the full target.
        final m = prefixSums.reduce(math.max);
        final lse =
            m + math.log(prefixSums.fold(0.0, (a, s) => a + math.exp(s - m)));
        for (final r in answer.ranked) {
          final j = listed.indexOf(r.id);
          maxPrefixVsFull = math.max(
            maxPrefixVsFull,
            (r.score - (prefixSums[j] - lse)).abs(),
          );
        }

        final top = answer.ranked.first.id;
        final topIndex = listed.indexOf(top);
        final ref = (options[topIndex]['reference_token_scores'] as List)
            .cast<num>();
        for (var i = 0; i < scoredLengths[topIndex]; i++) {
          maxTopToReference = math.max(
            maxTopToReference,
            (full.tokenScores[topIndex][i] - ref[i]).abs(),
          );
        }
        if (top == row['reference_argmax']) argmaxAgree++;

        // The section's rule on the decider's own probabilities.
        final ptop = p[top]!;
        final abstains =
            type == 'choice' &&
            (top == payload['none_option'] ||
                (below != null && below > 0 && ptop < below));
        expect(answer.choice, abstains ? null : top, reason: 'row $index');
        expect(answer.questionType.name, type);
        final goldenTop = (row['probabilities'] as List).cast<num>().reduce(
          math.max,
        );
        if (answer.choice == row['answer']) {
          answerAgree++;
        } else if (below != null && (goldenTop - below).abs() < _borderline) {
          borderline.add(
            'row $index: golden ${row['answer']} (p ${goldenTop.toStringAsFixed(4)}), '
            'here ${answer.choice} (p ${ptop.toStringAsFixed(4)}), '
            'threshold ${below.toStringAsFixed(4)}',
          );
        } else {
          fail(
            'row $index: answer ${answer.choice}, golden ${row['answer']} '
            '(p here ${ptop.toStringAsFixed(4)}, golden '
            '${goldenTop.toStringAsFixed(4)})',
          );
        }
        expect(p.values.fold(0.0, (a, v) => a + v), closeTo(1, 1e-9));
        // softmax(s / T) over the listed options, from the scores above.
        final mt = prefixSums.map((s) => s / temperature).reduce(math.max);
        final z = prefixSums.fold(
          0.0,
          (a, s) => a + math.exp(s / temperature - mt),
        );
        for (var j = 0; j < listed.length; j++) {
          expect(
            p[listed[j]]!,
            closeTo(math.exp(prefixSums[j] / temperature - mt) / z, 1e-6),
          );
        }
        final jev = answer.toJevJson();
        expect(jev['type'], type);
        switch (type) {
          case 'noul':
            expect(answer.noul, p['yes']);
            expect(jev['noul'], p['yes']);
          case 'score':
            var level = 0.0;
            for (var j = 0; j < listed.length; j++) {
              level += p[listed[j]]! * j;
            }
            expect(answer.expectedLevel, closeTo(level, 1e-9));
            expect(jev['score'], answer.expectedLevel);
            expect((jev['legend'] as Map).keys, listed);
          default:
            expect(jev['choice'], answer.choice);
        }
      }
      await scorer.close();
      await decider.close();
      times.sort();
      // ignore: avoid_print
      print(
        '[decider] ${_name(pack)}: ${rows.length} rows; top option = '
        'reference on $argmaxAgree; answer = golden on $answerAgree'
        '${borderline.isEmpty ? '' : '; borderline ${borderline.join('; ')}'}\n'
        '[decider]   max |here - reference| per token $maxToReference '
        '(top options only: $maxTopToReference)\n'
        '[decider]   max |here - golden engine| per token $maxToGoldenEngine '
        '(golden: ${provenance['cpu']}, LiteRT-LM '
        '${(provenance['runtime'] as Map?)?['litert-lm']}; here: '
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}, '
        '${Platform.numberOfProcessors} cores)\n'
        '[decider]   max |unique prefix - full target prefix| $maxPrefixVsFull\n'
        '[decider]   ms per decision: median ${times[times.length ~/ 2]}, '
        'max ${times.last}',
      );
      expect(argmaxAgree, rows.length);
      expect(maxToReference, lessThanOrEqualTo(_referenceBound));
      expect(maxPrefixVsFull, lessThan(1e-4));
    }, timeout: const Timeout(Duration(minutes: 20)));

    final twin = File('${pack.path}/twin.litertlm');
    test(
      '${_name(pack)}: the float32 twin is within 1e-3 nats of the reference',
      () async {
        final golden =
            jsonDecode(File('${pack.path}/golden.json').readAsStringSync())
                as Map<String, Object?>;
        final provenance = golden['provenance'] as Map<String, Object?>;
        final payload =
            (provenance['section'] as Map)['payload'] as Map<String, Object?>;
        final listed = [
          for (final o in (payload['options'] as List).cast<Map>())
            o['id'] as String,
          if (payload['none_option'] case final String none) none,
        ];
        final model = await _load(twin.path);
        final scorer = await (model as OptionScoringModel).openOptionScorer();
        final reprefill = provenance['twin_mode'] == 'once';
        var worst = 0.0;
        for (final row in (golden['rows'] as List).cast<Map>()) {
          final rendered = await scorer.renderUserMessage(
            row['user_message'] as String,
          );
          final ids = await scorer.tokenize(rendered);
          final last = await scorer.detokenize([ids.last]);
          final run = await scorer.score(rendered, [
            for (final id in listed) '$id${payload['terminator']}',
          ], reprefill: reprefill ? last : null);
          final options = (row['options'] as List).cast<Map>();
          for (var j = 0; j < listed.length; j++) {
            final ref = (options[j]['reference_token_scores'] as List)
                .cast<num>();
            for (var i = 0; i < ref.length; i++) {
              worst = math.max(worst, (run.tokenScores[j][i] - ref[i]).abs());
            }
          }
        }
        await scorer.close();
        // ignore: avoid_print
        print('[decider] ${_name(pack)} twin: max |twin - reference| $worst');
        expect(worst, lessThan(1e-3));
      },
      skip: twin.existsSync() ? false : 'no twin.litertlm staged',
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }

  group('refusals and coexistence, on the first choice pack', () {
    Directory? pack;
    Map<String, Object?>? payload;
    for (final candidate in packs) {
      final golden =
          jsonDecode(File('${candidate.path}/golden.json').readAsStringSync())
              as Map<String, Object?>;
      final p =
          ((golden['provenance'] as Map)['section'] as Map)['payload']
              as Map<String, Object?>;
      if (p['type'] == 'choice') {
        pack = candidate;
        payload = p;
        break;
      }
    }
    final skip = pack == null ? 'no choice pack staged' : false;
    final trained = payload ?? const <String, Object?>{};

    Future<InferenceModel> model() => _load('${pack!.path}/model.litertlm');

    Future<Decider> decider(InferenceModel m) => m.createDecider(
      question: trained['question'] as String,
      options: _options(trained),
      calibration: _calibration(trained),
    );

    test('arguments that are not the trained ones are refused', () async {
      final m = await model();
      final options = _options(trained);
      final calibration = _calibration(trained);
      final question = trained['question'] as String;
      Future<void> refused(
        Future<Decider> Function() create,
        String field,
      ) async {
        await expectLater(
          create(),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', field)),
        );
      }

      await refused(
        () => m.createDecider(
          question: '$question?',
          options: options,
          calibration: calibration,
        ),
        'question',
      );
      await refused(
        () => m.createDecider(
          question: question,
          options: options.sublist(1),
          calibration: calibration,
        ),
        'options',
      );
      await refused(
        () => m.createDecider(
          question: question,
          options: [...options, DeciderOption('not_trained')],
          calibration: calibration,
        ),
        'options',
      );
      await refused(
        () => m.createDecider(
          question: question,
          options: [
            DeciderOption(options.first.id, description: 'something else'),
            ...options.skip(1),
          ],
          calibration: calibration,
        ),
        'options',
      );
      await refused(
        () => m.createDecider(
          question: question,
          options: options,
          calibration: InferenceDeciderCalibration(
            temperature: calibration.temperature! + 0.1,
            abstainBelow: calibration.abstainBelow,
            noneOption: calibration.noneOption,
          ),
        ),
        'calibration.temperature',
      );
      await refused(
        () => m.createDecider(
          question: question,
          options: options,
          calibration: InferenceDeciderCalibration(
            temperature: calibration.temperature,
            noneOption: calibration.noneOption,
          ),
        ),
        'calibration.abstainBelow',
      );
      // Another order, and a description equal to the id, are accepted.
      final reordered = await m.createDecider(
        question: question,
        options: [
          for (final o in options.reversed)
            DeciderOption(o.id, description: o.description ?? o.id),
        ],
        calibration: calibration,
      );
      final answer = await reordered.choose(
        DeciderInput(EmbeddingInput.text('i feel so happy and grateful today')),
      );
      expect(answer.choice, isNotNull);
      await reordered.close();
    }, skip: skip);

    test('requests a v1 decider does not take are refused', () async {
      final d = await decider(await model());
      final text = DeciderInput(EmbeddingInput.text('i am fine'));
      await expectLater(
        d.choose(text, among: [d.options.first.id]),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      await expectLater(
        d.choose(
          DeciderInput(
            EmbeddingInput.text('i am fine'),
            context: const [Message(text: 'hello', isUser: true)],
          ),
        ),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.image(Uint8List(8)))),
        throwsA(isA<DeciderUnsupportedException>()),
      );
      for (final marker in ['<end_of_turn>', '<start_of_turn>', '<bos>']) {
        await expectLater(
          d.choose(DeciderInput(EmbeddingInput.text('i am $marker fine'))),
          throwsA(isA<ArgumentError>()),
          reason: marker,
        );
      }
      await expectLater(
        d.choose(DeciderInput(EmbeddingInput.text('   '))),
        throwsA(isA<ArgumentError>()),
      );
      final token = CancelToken()..cancel();
      await expectLater(
        d.choose(text, cancelToken: token),
        throwsA(isA<DeciderCancelledException>()),
      );
      await d.close();
      expect(d.isClosed, isTrue);
      await expectLater(d.choose(text), throwsA(isA<StateError>()));
    }, skip: skip);

    test(
      'a chat on the same model works between and beside decisions',
      () async {
        final m = await model();
        final d = await decider(m);
        final input = DeciderInput(
          EmbeddingInput.text('i am so scared of what tomorrow brings'),
        );
        final before = await d.choose(input);
        final chat = await m.createChat(topK: 1, maxOutputTokens: 16);
        await chat.addQueryChunk(
          const Message(text: 'Say hello.', isUser: true),
        );
        // A decision while the chat generates: the native lock orders them.
        final reply = chat.generateChatResponseAsync().toList();
        final during = await d.choose(input);
        final chunks = await reply;
        expect(chunks, isNotEmpty);
        final after = await d.choose(input);
        expect(during.probabilities, before.probabilities);
        expect(after.probabilities, before.probabilities);
        await d.close();
      },
      skip: skip,
    );

    test('a model without a decision section is refused', () async {
      final path = '$_documents/functiongemma-270M-it.litertlm';
      if (!File(path).existsSync()) {
        markTestSkipped('FunctionGemma 270M is not staged at $path');
        return;
      }
      final m = await _load(path, modelType: ModelType.functionGemma);
      expect(await (m as OptionScoringModel).readDecisionSection(), isNull);
      await expectLater(
        m.createDecider(
          question: trained['question'] as String,
          options: _options(trained),
          calibration: _calibration(trained),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('no decision section'),
          ),
        ),
      );
    }, skip: skip);

    test('a model on the GPU is refused: only the CPU is measured', () async {
      final m = await _load(
        '${pack!.path}/model.litertlm',
        backend: PreferredBackend.gpu,
      );
      expect(m.activeBackend, PreferredBackend.gpu);
      await expectLater(
        decider(m),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('CPU'),
          ),
        ),
      );
    }, skip: skip);
  });
}
