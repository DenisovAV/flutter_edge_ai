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
// quantisation in between; without one that test is skipped, and the
// method is checked only through the int8 bounds below. The refusal tests also
// need FunctionGemma 270M (`functiongemma-270M-it.litertlm`, a chat model
// without a decision) and, for the self-check on another template,
// `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` in the container Documents.
//
// What is asserted per row, on this machine: the rendered prompt and its
// token ids are the golden ones; the decider's top option is the argmax of
// its own scores, and the reference's — or within 1 nat of it (int8 flips
// near-ties: litetune's own run of the Score pack disagrees with its
// reference on 3 of 24 rows), on at most 2 rows more than litetune's own run;
// its answer follows the section's rule on its own scores, and is the golden
// answer unless the golden top probability is within 0.05 of the threshold
// (another CPU's int8 kernels move a probability that close across it);
// every token is within 2.0 nats of the reference; a target scored alone
// equals the same target scored after a rewind. The gap to the golden engine
// scores is printed, not asserted: it measures this CPU's int8 arithmetic
// against the one litetune ran on.
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
/// litetune's Xeon, 1.8833 on an Apple M4 Pro (2026-10-18). Wrong scoring
/// (the other #3561 mode) is 8.75 nats off.
const _referenceBound = 2.0;

/// A golden answer whose top probability is this close to the threshold may
/// fall on the other side on another CPU.
const _borderline = 0.05;

/// A reference margin within which int8 may rank the two options either way:
/// litetune measured disagreements with its reference at margins up to 0.637
/// nats (irony, E8) and 0.186 (SST-5).
const _nearTie = 1.0;

/// How many more rows than litetune's own run may disagree with the
/// reference on this CPU.
const _extraFlips = 2;

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

/// The trained options without the none option: the call LiteTune prints,
/// with `InferenceDeciderCalibration.fromModel()`.
List<DeciderOption> _trainedOptions(Map<String, Object?> payload) => [
  for (final o in (payload['options'] as List).cast<Map<String, Object?>>())
    DeciderOption(o['id'] as String, description: o['description'] as String?),
];

/// Every listed option, the none option included: the call with explicit
/// values.
List<DeciderOption> _listedOptions(Map<String, Object?> payload) => [
  ..._trainedOptions(payload),
  if (payload['none_option'] case final String none) DeciderOption(none),
];

InferenceDeciderCalibration _explicitCalibration(Map<String, Object?> payload) {
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

/// The scoring mode the model's self-check picked (`LiteRtLmScoringMode`,
/// internal to flutter_edge_ai_litertlm).
String? _modeOf(InferenceModel model) =>
    ((model as dynamic).scoringMode as Enum?)?.name;

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

Map<String, Object?> _goldenOf(Directory pack) =>
    jsonDecode(File('${pack.path}/golden.json').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _payloadOf(Map<String, Object?> golden) =>
    ((golden['provenance'] as Map)['section'] as Map)['payload']
        as Map<String, Object?>;

/// A greedy chat's second reply, with [between] run between its two turns.
Future<String> _secondTurn(
  InferenceModel model, {
  Future<void> Function()? between,
}) async {
  final chat = await model.createChat(topK: 1, maxOutputTokens: 24);
  try {
    Future<String> turn(String text) async {
      await chat.addQueryChunk(Message(text: text, isUser: true));
      final reply = StringBuffer();
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) reply.write(r.token);
      }
      return reply.toString();
    }

    await turn('Remember the word PELICAN. Reply OK.');
    if (between != null) await between();
    return await turn('Which word did I ask you to remember?');
  } finally {
    await chat.close();
  }
}

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
    // One pack alone would leave the other question types unchecked while
    // the suite stays green.
    final types = {
      for (final pack in packs)
        (((_goldenOf(pack)['provenance'] as Map)['section'] as Map)['payload']
                as Map)['type']
            as String,
    };
    expect(
      types,
      containsAll(['choice', 'noul', 'score']),
      reason: 'stage a golden pack of each question type in ${_packsDir.path}',
    );
  });

  for (final pack in packs) {
    test('${_name(pack)}: every golden row on the real model', () async {
      final golden = _goldenOf(pack);
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

      // The call LiteTune prints: the question, the trained options, and the
      // file's calibration.
      final created = Stopwatch()..start();
      final decider = await model.createDecider(
        question: payload['question'] as String,
        options: _trainedOptions(payload),
        calibration: const InferenceDeciderCalibration.fromModel(),
      );
      created.stop();
      final mode = _modeOf(model);
      // ignore: avoid_print
      print(
        '[decider] ${_name(pack)}: $type, ${listed.length} options, '
        'created in ${created.elapsedMilliseconds} ms, mode $mode '
        '(golden ${provenance['mode']})',
      );
      expect(mode, provenance['mode']);
      expect(decider.capabilities.questionType.name, type);
      expect(decider.options.map((o) => o.id), listed);

      final scorer = await engine.openOptionScorer();
      final fullTargets = [for (final id in listed) '$id$terminator'];
      var maxToReference = 0.0;
      var maxToGoldenEngine = 0.0;
      var maxTopToReference = 0.0;
      var maxPrefixVsFull = 0.0;
      var maxAloneVsRun = 0.0;
      var argmaxAgree = 0;
      var engineAgree = 0;
      var answerAgree = 0;
      final nearTies = <String>[];
      final borderline = <String>[];
      final times = <int>[];
      final rows = (golden['rows'] as List).cast<Map<String, Object?>>();
      for (var r = 0; r < rows.length; r++) {
        final row = rows[r];
        final index = row['index'];
        final state = row['state'] as String;
        final userMessage = _render(payload, state);
        expect(userMessage, row['user_message'], reason: 'row $index');

        // The prompt the engine renders, as its tokens.
        final rendered = await scorer.renderUserMessage(userMessage);
        final ids = await scorer.tokenize(rendered);
        expect(ids, row['engine_prompt_ids'], reason: 'row $index');
        expect(ids.length + 1, row['prompt_tokens_with_bos']);

        // Every token of every option's full target, as the reference has
        // them.
        final full = await scorer.score(rendered, fullTargets);
        if (r < 3) {
          // Each target scored in a session of its own equals the same target
          // scored after the checkpoint's rewind.
          for (var j = 0; j < listed.length; j++) {
            final alone = await scorer.score(rendered, [fullTargets[j]]);
            for (var i = 0; i < alone.tokenScores.single.length; i++) {
              maxAloneVsRun = math.max(
                maxAloneVsRun,
                (alone.tokenScores.single[i] - full.tokenScores[j][i]).abs(),
              );
            }
          }
        }
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
        for (final ranked in answer.ranked) {
          final j = listed.indexOf(ranked.id);
          maxPrefixVsFull = math.max(
            maxPrefixVsFull,
            (ranked.score - (prefixSums[j] - lse)).abs(),
          );
        }

        final top = answer.ranked.first.id;
        final topIndex = listed.indexOf(top);
        expect(
          topIndex,
          prefixSums.indexOf(m),
          reason: 'row $index: the top option is the argmax of the scores',
        );
        final ref = (options[topIndex]['reference_token_scores'] as List)
            .cast<num>();
        for (var i = 0; i < scoredLengths[topIndex]; i++) {
          maxTopToReference = math.max(
            maxTopToReference,
            (full.tokenScores[topIndex][i] - ref[i]).abs(),
          );
        }
        // The top option is the reference's, or a near-tie of the reference's
        // top: int8 moves a score by up to about a nat, so a margin under
        // [_nearTie] can flip on any CPU.
        double behind(String key) {
          final sums = [for (final o in options) (o[key] as num).toDouble()];
          return sums.reduce(math.max) - sums[topIndex];
        }

        if (top == row['reference_argmax']) {
          argmaxAgree++;
        } else {
          nearTies.add(
            'row $index: here $top, reference ${row['reference_argmax']} '
            '(${behind('reference_sum').toStringAsFixed(3)} nats behind), '
            'golden engine ${row['engine_argmax']}',
          );
          expect(
            behind('reference_sum'),
            lessThanOrEqualTo(_nearTie),
            reason: 'row $index: $top is not a near-tie of the reference top',
          );
        }
        if (top == row['engine_argmax']) {
          engineAgree++;
        } else {
          expect(
            behind('engine_sum'),
            lessThanOrEqualTo(_nearTie),
            reason: 'row $index: $top is not a near-tie of the golden top',
          );
        }

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
        } else if (top != row['engine_argmax']) {
          // A near-tie of the golden top, checked above.
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
      final goldenAgree =
          (golden['tolerances']
                  as Map)['engine_argmax_equals_reference_argmax_rows']
              as int;
      // ignore: avoid_print
      print(
        '[decider] ${_name(pack)}: ${rows.length} rows; top option = '
        'reference on $argmaxAgree (golden engine on $engineAgree, golden '
        'engine = reference on $goldenAgree); answer = golden on $answerAgree'
        '${nearTies.isEmpty ? '' : '\n[decider]   near ties: ${nearTies.join('; ')}'}'
        '${borderline.isEmpty ? '' : '\n[decider]   at the threshold: ${borderline.join('; ')}'}\n'
        '[decider]   max |here - reference| per token $maxToReference '
        '(top options only: $maxTopToReference)\n'
        '[decider]   max |here - golden engine| per token $maxToGoldenEngine '
        '(golden: ${provenance['cpu']}, LiteRT-LM '
        '${(provenance['runtime'] as Map?)?['litert-lm']}; here: '
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}, '
        '${Platform.numberOfProcessors} cores)\n'
        '[decider]   max |unique prefix - full target prefix| $maxPrefixVsFull; '
        'max |alone - after a rewind| $maxAloneVsRun\n'
        '[decider]   ms per decision: median ${times[times.length ~/ 2]}, '
        'max ${times.last}',
      );
      expect(argmaxAgree, greaterThanOrEqualTo(goldenAgree - _extraFlips));
      expect(maxToReference, lessThanOrEqualTo(_referenceBound));
      expect(maxPrefixVsFull, lessThan(1e-4));
      expect(maxAloneVsRun, 0.0);
    }, timeout: const Timeout(Duration(minutes: 20)));

    final twin = File('${pack.path}/twin.litertlm');
    test(
      '${_name(pack)}: the float32 twin is within 1e-3 nats of the reference',
      () async {
        final golden = _goldenOf(pack);
        final payload = _payloadOf(golden);
        final listed = [
          for (final o in (payload['options'] as List).cast<Map>())
            o['id'] as String,
          if (payload['none_option'] case final String none) none,
        ];
        final model = await _load(twin.path);
        final scorer = await (model as OptionScoringModel).openOptionScorer();
        var worst = 0.0;
        for (final row in (golden['rows'] as List).cast<Map>()) {
          final rendered = await scorer.renderUserMessage(
            row['user_message'] as String,
          );
          final run = await scorer.score(rendered, [
            for (final id in listed) '$id${payload['terminator']}',
          ]);
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
      skip: twin.existsSync()
          ? false
          : 'no twin.litertlm staged: the method is checked only through the '
                'int8 bounds',
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }

  group('refusals, coexistence and stopping, on the first choice pack', () {
    Directory? pack;
    Map<String, Object?>? payload;
    for (final candidate in packs) {
      final p = _payloadOf(_goldenOf(candidate));
      if (p['type'] == 'choice') {
        pack = candidate;
        payload = p;
        break;
      }
    }
    final skip = pack == null ? 'no choice pack staged' : false;
    final trained = payload ?? const <String, Object?>{};
    final question = trained['question'] as String? ?? '';

    Future<InferenceModel> model() => _load('${pack!.path}/model.litertlm');

    Future<Decider> decider(InferenceModel m) => m.createDecider(
      question: question,
      options: _trainedOptions(trained),
      calibration: const InferenceDeciderCalibration.fromModel(),
    );

    final input = DeciderInput(
      EmbeddingInput.text('i am so scared of what tomorrow brings'),
    );

    test('explicit values must be the file\'s; other arguments are '
        'refused', () async {
      final m = await model();
      final options = _listedOptions(trained);
      final calibration = _explicitCalibration(trained);
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
      // The file's own values, given explicitly, are accepted.
      final explicit = await m.createDecider(
        question: question,
        options: options,
        calibration: calibration,
      );
      final fromModel = await decider(m);
      expect(
        (await explicit.choose(input)).probabilities,
        (await fromModel.choose(input)).probabilities,
      );
      await explicit.close();
      await fromModel.close();
    }, skip: skip);

    test('another option order gives the same answer', () async {
      final m = await model();
      final trainedOrder = await decider(m);
      final reversed = await m.createDecider(
        question: question,
        options: [
          for (final o in _trainedOptions(trained).reversed)
            DeciderOption(o.id, description: o.description ?? o.id),
        ],
        calibration: const InferenceDeciderCalibration.fromModel(),
      );
      final a = await trainedOrder.choose(input);
      final b = await reversed.choose(input);
      expect(b.probabilities, a.probabilities);
      expect(b.choice, a.choice);
      await trainedOrder.close();
      await reversed.close();
    }, skip: skip);

    test('requests a v1 decider does not take are refused', () async {
      final d = await decider(await model());
      await expectLater(
        d.choose(input, among: [d.options.first.id]),
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
        d.choose(input, cancelToken: token),
        throwsA(isA<DeciderCancelledException>()),
      );
      await d.close();
      expect(d.isClosed, isTrue);
      await expectLater(d.choose(input), throwsA(isA<StateError>()));
    }, skip: skip);

    test(
      'an input longer than the context is refused, not truncated',
      () async {
        final d = await decider(await model());
        await expectLater(
          d.choose(DeciderInput(EmbeddingInput.text('i feel ' * 600))),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('maxTokens 1024'),
            ),
          ),
        );
        // The decider still answers.
        expect((await d.choose(input)).ranked, isNotEmpty);
        await d.close();
      },
      skip: skip,
    );

    test('a chat\'s next turn is the same after a decision, and after a '
        'decider\'s creation, between its turns', () async {
      final m = await model();
      final plain = await _secondTurn(m);
      final d = await decider(m);
      final afterDecision = await _secondTurn(
        m,
        between: () async {
          await d.choose(input);
        },
      );
      final afterCreation = await _secondTurn(
        m,
        between: () async {
          final fresh = await decider(m);
          await fresh.choose(input);
          await fresh.close();
        },
      );
      // ignore: avoid_print
      print(
        '[decider] second turn: plain ${jsonEncode(plain)}, after a decision '
        '${jsonEncode(afterDecision)}, after a creation '
        '${jsonEncode(afterCreation)}',
      );
      expect(afterDecision, plain);
      expect(afterCreation, plain);
      await d.close();
    }, skip: skip);

    test('a decision waits for a chat turn on the same model', () async {
      final m = await model();
      final d = await decider(m);
      final before = await d.choose(input);
      final chat = await m.createChat(topK: 1, maxOutputTokens: 16);
      try {
        await chat.addQueryChunk(
          const Message(text: 'Say hello.', isUser: true),
        );
        // A decision while the chat generates: the native lock orders them.
        final reply = chat.generateChatResponseAsync().toList();
        final during = await d.choose(input);
        expect(await reply, isNotEmpty);
        final after = await d.choose(input);
        expect(during.probabilities, before.probabilities);
        expect(after.probabilities, before.probabilities);
      } finally {
        await chat.close();
        await d.close();
      }
    }, skip: skip);

    test('a cancel stops a long scoring run between targets', () async {
      final m = await model();
      final scorer = await (m as OptionScoringModel).openOptionScorer();
      final targets = [
        for (final o in _listedOptions(trained))
          '${o.id}${trained['terminator']}',
      ];
      final many = List.generate(300, (i) => targets[i % targets.length]);
      final rendered = await scorer.renderUserMessage('a state to score');
      await scorer.prepare(targets);
      final token = CancelToken();
      final watch = Stopwatch()..start();
      final run = expectLater(
        scorer.score(rendered, many, cancelToken: token),
        throwsA(isA<DeciderCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      await run;
      // ignore: avoid_print
      print(
        '[decider] a 300-target run cancelled at 100 ms ended at '
        '${watch.elapsedMilliseconds} ms',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      await scorer.close();
    }, skip: skip);

    test(
      'closing the scorer stops its long run and frees the engine',
      () async {
        final m = await model();
        final scorer = await (m as OptionScoringModel).openOptionScorer();
        final targets = [
          for (final o in _listedOptions(trained))
            '${o.id}${trained['terminator']}',
        ];
        final many = List.generate(300, (i) => targets[i % targets.length]);
        final rendered = await scorer.renderUserMessage('a state to score');
        await scorer.prepare(targets);
        final watch = Stopwatch()..start();
        final run = expectLater(
          scorer.score(rendered, many),
          throwsA(isA<StateError>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await scorer.close();
        await run;
        final stopped = watch.elapsedMilliseconds;
        // The engine is free again: another scorer's one-target run starts now.
        final next = await m.openOptionScorer();
        await next.prepare(targets);
        final one = await next.score(rendered, [targets.first]);
        // ignore: avoid_print
        print(
          '[decider] closing the scorer at 100 ms ended its 300-target run at '
          '$stopped ms',
        );
        expect(stopped, lessThan(3000));
        expect(one.tokenScores.single, isNotEmpty);
        await next.close();
      },
      skip: skip,
    );

    test('a scorer closed during the shared self-check does not fail the '
        'scorer waiting on it', () async {
      final targets = [
        for (final o in _listedOptions(trained))
          '${o.id}${trained['terminator']}',
      ];
      // Close at once (the check is still tokenizing) and later (it scores).
      for (final delay in const [Duration.zero, Duration(milliseconds: 30)]) {
        // A fresh model, so that its self-check has not run yet.
        await (await model()).close();
        final m = await model() as OptionScoringModel;
        final a = await m.openOptionScorer();
        final b = await m.openOptionScorer();
        final aPrepared = expectLater(
          a.prepare(targets),
          throwsA(isA<StateError>()),
        );
        final bPrepared = b.prepare(targets);
        await Future<void>.delayed(delay);
        await a.close();
        await aPrepared;
        await bPrepared;
        // ignore: avoid_print
        print(
          '[decider] scorer closed at ${delay.inMilliseconds} ms during the '
          'self-check: the other one got mode ${_modeOf(m as InferenceModel)}',
        );
        expect(_modeOf(m as InferenceModel), 'once');
        await b.close();
      }
    }, skip: skip);

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
          question: question,
          options: _trainedOptions(trained),
          calibration: const InferenceDeciderCalibration.fromModel(),
        ),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('carries no decision'),
          ),
        ),
      );
    }, skip: skip);

    test(
      'the self-check also tells the mode on another chat template',
      () async {
        final path = '$_documents/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm';
        if (!File(path).existsSync()) {
          markTestSkipped('Qwen3 0.6B is not staged at $path');
          return;
        }
        final m = await _load(path, modelType: ModelType.qwen3);
        final scorer = await (m as OptionScoringModel).openOptionScorer();
        await scorer.prepare([
          'yes<|im_end|>',
          'no<|im_end|>',
          'maybe<|im_end|>',
        ]);
        // ignore: avoid_print
        print('[decider] Qwen3 0.6B self-check: ${_modeOf(m)}');
        expect(_modeOf(m), 'once');
        await scorer.close();
      },
      skip: skip,
    );

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

    test('closing the model stops a long scoring run', () async {
      final m = await model();
      final scorer = await (m as OptionScoringModel).openOptionScorer();
      final targets = [
        for (final o in _listedOptions(trained))
          '${o.id}${trained['terminator']}',
      ];
      final many = List.generate(300, (i) => targets[i % targets.length]);
      final rendered = await scorer.renderUserMessage('a state to score');
      // The self-check first, so that the close lands in the long run.
      await scorer.prepare(targets);
      final watch = Stopwatch()..start();
      final run = expectLater(
        scorer.score(rendered, many),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await m.close();
      final closed = watch.elapsed;
      await run;
      // ignore: avoid_print
      print(
        '[decider] closing during a 300-target run took '
        '${closed.inMilliseconds - 100} ms',
      );
      expect(closed, lessThan(const Duration(seconds: 3)));
    }, skip: skip);
  });
}
