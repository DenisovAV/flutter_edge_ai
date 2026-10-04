/// Upstream LiteRT-LM #2080 retest — are per-session sampler params still
/// baked at the engine's FIRST generation on v0.16.0?
///
/// Reproduces the signature posted upstream on 2026-07-28 (v0.14.0, macOS
/// arm64, Gemma 4 E2B):
///
///   G = greedy   (topK=1,  temp=0.8, seed=1) on engine A, first generation
///   X = stochastic (topK=64, temp=1.5, seed=7) on the SAME engine A
///   Y = stochastic again on the SAME engine A
///   Z = stochastic on a FRESH engine B          <- control
///   G2= greedy    (same params as G) on a FRESH engine C   <- anchor
///
///   bug present : X == Y == G  and  Z != G   (engine locked to what the first
///                                             generation baked)
///   bug fixed   : X != G                     (later sessions honour params)
///
/// Two controls, because each rules out a different way of passing wrongly.
/// Z != G proves the stochastic params *can* produce different text, so an
/// X == G is baking rather than a prompt too peaked to diverge. G2 == G proves
/// the greedy params took effect at all — without it, a build that ignores
/// sampler params *entirely* makes G stochastic, X/Y/Z differ from it by
/// chance, and the harness reports "fixed" on a build that honours nothing.
///
/// Run: cd example && flutter test integration_test/sampler_baking_2080_test.dart -d macos
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

String get _macosDir =>
    '${Platform.environment['HOME']}/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents';
String get _model => '$_macosDir/gemma-4-E2B-it.litertlm';

const _prompt =
    'Invent a name for a cosy coffee shop. Answer with the name only.';

/// One generation on [model] with the given sampler params.
Future<String> _gen(
  InferenceModel model, {
  required int topK,
  required double temperature,
  required int randomSeed,
}) async {
  final session = await model.createSession(
    temperature: temperature,
    topK: topK,
    randomSeed: randomSeed,
  );
  try {
    await session.addQueryChunk(const Message(text: _prompt, isUser: true));
    return (await session.getResponse()).trim();
  } finally {
    await session.close();
  }
}

Future<InferenceModel> _engine() => FlutterEdgeAi.getActiveModel(
  maxTokens: 1024,
  preferredBackend: PreferredBackend.cpu,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    expect(
      File(_model).existsSync(),
      isTrue,
      reason: 'model missing at $_model',
    );
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(_model).install();
  });

  testWidgets(
    '#2080 — later sessions must honour their own sampler params',
    (_) async {
      // close() must run on every path. The desktop shell dedupes engines on
      // name + (supportImage, supportAudio, maxTokens) and NOT on backend, and
      // all three _engine() calls here are identical — so a leaked engineA is
      // handed straight back as engineB, and Z silently stops being a fresh
      // engine. The control the whole verdict rests on would quietly become a
      // fourth same-engine generation.
      final String g, x, y, z, g2;

      final engineA = await _engine();
      try {
        g = await _gen(engineA, topK: 1, temperature: 0.8, randomSeed: 1);
        x = await _gen(engineA, topK: 64, temperature: 1.5, randomSeed: 7);
        y = await _gen(engineA, topK: 64, temperature: 1.5, randomSeed: 7);
      } finally {
        await engineA.close();
      }

      final engineB = await _engine();
      try {
        z = await _gen(engineB, topK: 64, temperature: 1.5, randomSeed: 7);
      } finally {
        await engineB.close();
      }

      // Anchor: a third engine whose FIRST generation is greedy with G's exact
      // params. Without it, "x != g" also passes when sampler params are
      // ignored ENTIRELY rather than baked — G would then be stochastic, X/Y/Z
      // would differ from it by chance, and the harness would report "fixed" on
      // a build that honours nothing. topK:1 is deterministic, so g2 == g is a
      // hard invariant when the params take effect at all. It must be a third
      // engine: under the bug engineB is already baked stochastic.
      final engineC = await _engine();
      try {
        g2 = await _gen(engineC, topK: 1, temperature: 0.8, randomSeed: 1);
      } finally {
        await engineC.close();
      }

      // ignore: avoid_print
      print(
        '[#2080] G (greedy, engine A first)="$g"\n'
        '[#2080] X (stoch, same engine)="$x"\n'
        '[#2080] Y (stoch, same engine)="$y"\n'
        '[#2080] Z (stoch, fresh engine B)="$z"\n'
        '[#2080] G2(greedy, fresh engine C)="$g2"',
      );

      // Anchor first: greedy must be reproducible, or nothing below means
      // anything.
      expect(
        g2,
        equals(g),
        reason:
            'INCONCLUSIVE: two engines given identical greedy params '
            '(topK 1) produced different text — sampler params are not being '
            'honoured at all, so "X != G" would prove nothing',
      );

      // Control: if the fresh engine also returns G, the prompt is too peaked
      // to distinguish anything and the whole result is inconclusive.
      expect(
        z,
        isNot(equals(g)),
        reason:
            'INCONCLUSIVE: a fresh engine with stochastic params produced '
            'the greedy output too — pick a less deterministic prompt',
      );

      expect(
        x,
        isNot(equals(g)),
        reason:
            'FAIL = #2080 still reproduces on v0.16.0: the engine stayed '
            'locked to what the first (greedy) generation baked',
      );
      expect(y, isNot(equals(g)), reason: 'same, second stochastic session');
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
