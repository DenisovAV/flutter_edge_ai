// Decider latency on a device with EmbeddingGemma 2 text 270m: for N = 10,
// 150, 500 and 2000 zero-shot options, how long createDecider takes (one
// embedding per option description) and how long one choose() takes — wall
// time, and the embed / score split the answer's provenance reports. Numbers
// only: it asserts that the decider answers, not how fast.
//
// The options are synthetic phone/home actions ("turn on the kitchen lights
// for tomorrow"), 2000 distinct ones, so N options are a prefix of one fixed
// list; the queries are paraphrases of some of them.
//
// No setUp/setUpAll (Rule 6b): the test body calls the guarded `_ensureEg2()`
// first. Run (macOS, Android, iOS, Linux, Windows):
//   flutter test integration_test/decider_benchmark_test.dart -d <device>
// Optional: --dart-define=EG2_MODEL_FILE=<a local copy of the pinned bundle
// the app can read> (on macOS, inside the app's sandbox container), or
// EG2_MODEL_URL=<a mirror of the same bytes>.

// The Decider API is @experimental; using it is the point of this file.
// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');

bool _initialized = false;

Future<void> _ensureEg2() async {
  if (!_initialized) {
    await FlutterEdgeAi.initialize(
      embeddingBackends: const [LiteRtEmbeddingBackend()],
    );
    _initialized = true;
  }
  final builder = FlutterEdgeAi.installEmbedder();
  if (_fileOverride.isNotEmpty) {
    builder.modelFromFile(_fileOverride, filename: _eg2.filename);
  } else {
    builder.modelFromNetwork(
      _urlOverride.isEmpty ? _eg2.url : _urlOverride,
      filename: _eg2.filename,
    );
  }
  await builder.install();
}

const _verbs = [
  'turn on',
  'turn off',
  'open',
  'close',
  'lock',
  'unlock',
  'dim',
  'check',
  'start',
  'stop',
  'pause',
  'resume',
  'schedule',
  'cancel',
  'share',
  'find',
  'clean',
  'order',
  'book',
  'record',
];

const _objects = [
  'the kitchen lights',
  'the bedroom lights',
  'the front door',
  'the garage door',
  'the thermostat',
  'the air conditioner',
  'the washing machine',
  'the dishwasher',
  'the robot vacuum',
  'the coffee machine',
  'the oven',
  'the living room TV',
  'the bathroom fan',
  'the garden sprinklers',
  'the security camera',
  'the blinds',
  'the music in the hall',
  'a taxi to the airport',
  'a table for two',
  'the weekly groceries',
  'a video call with mum',
  'the morning alarm',
  'a reminder to pay rent',
  'the photo backup',
  'the guest wifi',
];

const _contexts = ['', ' for tomorrow', ' in ten minutes', ' tonight'];

/// 2000 distinct actions; the first N are a decider's options.
final List<String> _actions = [
  for (final context in _contexts)
    for (final object in _objects)
      for (final verb in _verbs) '$verb $object$context',
];

const _queries = [
  'switch the kitchen lights on please',
  'can you make it warmer in here',
  'is the front door locked',
  'shut the garage',
  'stop the dishwasher',
  'start a load of laundry tonight',
  'I need a cab to the airport tomorrow',
  'reserve a table for two',
  'play some music in the hallway',
  'wake me up early tomorrow',
  'remind me to pay the rent',
  'lower the blinds',
  'what is the security camera seeing',
  'water the garden in ten minutes',
  'make me a coffee',
  'call my mother on video',
  'clean the floors with the robot',
  'turn the TV off',
  'back up my photos tonight',
  'give the guests the wifi password',
];

int _ms(Duration d) => d.inMicroseconds ~/ 1000;

String _stats(List<Duration> samples) {
  final us = [for (final d in samples) d.inMicroseconds]..sort();
  double at(double q) => us[((us.length - 1) * q).round()] / 1000;
  return 'median ${at(0.5).toStringAsFixed(2)} ms, '
      'p90 ${at(0.9).toStringAsFixed(2)} ms, '
      'min ${(us.first / 1000).toStringAsFixed(2)} ms (n=${us.length})';
}

void _log(String line) {
  // ignore: avoid_print
  print('[decider-bench] $line');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('choose() latency at 10 / 150 / 500 / 2000 options (EG2 270m)', () async {
    await _ensureEg2();
    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    _log(
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}; '
      'backend ${embedder.activeBackend?.name}; dimension ${embedder.dimension}',
    );
    expect(_actions.toSet(), hasLength(2000));

    for (final n in [10, 150, 500, 2000]) {
      final watch = Stopwatch()..start();
      final decider = await embedder.createDecider(
        options: [
          for (final action in _actions.take(n))
            DeciderOption(action, description: action),
        ],
        calibration: const DeciderCalibration.none(),
      );
      final created = watch.elapsed;

      for (final q in _queries.take(3)) {
        await decider.choose(DeciderInput(EmbeddingInput.text(q)));
      }
      final wall = <Duration>[];
      final embed = <Duration>[];
      final score = <Duration>[];
      String? sample;
      for (var round = 0; round < 3; round++) {
        for (final q in _queries) {
          watch
            ..reset()
            ..start();
          final answer = await decider.choose(
            DeciderInput(EmbeddingInput.text(q)),
          );
          wall.add(watch.elapsed);
          embed.add(answer.provenance.embedTime);
          score.add(answer.provenance.scoreTime);
          expect(answer.choice, isNotNull);
          expect(answer.ranked, hasLength(5));
          sample ??=
              '"$q" → ${answer.choice} '
              '(cosine ${answer.provenance.similarity?.toStringAsFixed(3)}, '
              'margin ${answer.margin.toStringAsFixed(3)})';
        }
      }
      _log(
        'N=$n: createDecider ${_ms(created)} ms '
        '(${(created.inMicroseconds / n / 1000).toStringAsFixed(2)} ms/option)',
      );
      _log('N=$n: choose wall  ${_stats(wall)}');
      _log('N=$n: choose embed ${_stats(embed)}');
      _log('N=$n: choose score ${_stats(score)}');
      _log('N=$n: e.g. $sample');
      await decider.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
