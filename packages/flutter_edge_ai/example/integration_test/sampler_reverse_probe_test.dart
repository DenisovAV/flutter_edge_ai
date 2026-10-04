/// Falsification probe for the #2080 diagnosis — NOT a regression test.
///
/// sampler_baking_2080_test.dart concludes "the engine bakes whatever its first
/// generation used". That conclusion makes a prediction that has nothing to do
/// with greedy being a special case, and this file tests it:
///
///   Engine D, FIRST session STOCHASTIC (topK 64, temp 1.5, seed 7)  -> S
///   Engine D, LATER session GREEDY     (topK 1,  temp 0.8, seed 1)  -> Gd
///
///   baking real      : Gd == S   (locked to the stochastic first generation)
///   baking not real  : Gd == G   (the greedy text a fresh greedy engine gives)
///
/// The two outcomes are mutually exclusive and both are observable, so this
/// cannot come back "inconclusive" the way a single-direction test can. If Gd
/// comes out equal to the known greedy text, the baking diagnosis is wrong and
/// the docs' "honored natively" claim is right.
///
/// Run: cd example && flutter test integration_test/sampler_reverse_probe_test.dart -d macos
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
    'reverse probe — does a stochastic-first engine bake stochastic?',
    (_) async {
      final String g, s, gd;

      // Reference: what greedy looks like on an engine that starts greedy.
      final refEngine = await _engine();
      try {
        g = await _gen(refEngine, topK: 1, temperature: 0.8, randomSeed: 1);
      } finally {
        await refEngine.close();
      }

      // The probe: stochastic FIRST, greedy SECOND, same engine.
      //
      // Both sessions use seed 7 deliberately. The first run of this probe
      // varied topK/temperature AND the seed together, and produced a third
      // value that matched neither hypothesis — because under baked stochastic
      // params a different seed still gives different text. Holding the seed
      // fixed makes the two outcomes exactly comparable: if the later greedy
      // session returns S verbatim, topK/temperature were baked.
      final engineD = await _engine();
      String s2;
      try {
        s = await _gen(engineD, topK: 64, temperature: 1.5, randomSeed: 7);
        // Identical request to S. If params were re-applied per session the
        // seed would be re-seeded and this must equal S; if the engine baked
        // them and simply keeps drawing, the RNG stream has advanced and it
        // will differ. Either way it separates "re-applied" from "baked".
        s2 = await _gen(engineD, topK: 64, temperature: 1.5, randomSeed: 7);
        gd = await _gen(engineD, topK: 1, temperature: 0.8, randomSeed: 7);
      } finally {
        await engineD.close();
      }
      // ignore: avoid_print
      print('[probe] S2 (identical request to S)         ="$s2"');

      // ignore: avoid_print
      print(
        '[probe] G  (greedy on a greedy-first engine) ="$g"\n'
        '[probe] S  (stochastic, engine D first)      ="$s"\n'
        '[probe] Gd (greedy, engine D second)         ="$gd"\n'
        '[probe] verdict: ${gd == g ? "BAKING DISPROVED — the greedy request was honoured" : "BAKING CONFIRMED — engine D never returned to greedy; it kept "
                  "sampling from what its first generation baked"}',
      );

      // Control: if stochastic and greedy coincide on this prompt, nothing
      // below can be told apart.
      expect(
        s,
        isNot(equals(g)),
        reason:
            'INCONCLUSIVE: stochastic and greedy produced the same text on a '
            'fresh engine, so the two outcomes are indistinguishable here',
      );

      // 1. An identical repeat request must reproduce, if the seed is applied
      //    per session. It does not — the RNG stream simply carries on.
      expect(
        s2,
        isNot(equals(s)),
        reason:
            'the second identical stochastic request reproduced "$s2", which '
            'would mean seeds ARE re-applied per session — that contradicts '
            'the baking diagnosis and this probe should be rewritten',
      );

      // 2. The decisive one. Greedy (topK 1) is argmax: deterministic, seed
      //    independent. A session that asks for greedy and does not get the
      //    greedy answer did not get its parameters.
      expect(
        gd,
        isNot(equals(g)),
        reason:
            'the greedy request on engine D returned the greedy answer, so '
            'later sessions DO honour their params — #2080 would be fixed',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
