/// Upstream LiteRT-LM #2080 retest — are per-session sampler params still
/// baked at the engine's FIRST generation?
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
/// The run prints one `[#2080] VERDICT:` line before asserting — FIXED,
/// PRESENT, MIXED (one of X/Y equals G) or INCONCLUSIVE — and passes only on
/// FIXED.
///
/// Backend: CPU by default; `--dart-define=LATCH_BACKEND=gpu` for the GPU.
/// Every engine must report the backend asked for: a GPU load that fell back
/// to the CPU would test the CPU sampler under a GPU label.
///
/// Model: gemma-4-E2B-it.litertlm. macOS: ~/models (container Documents
/// fallback); Android: /data/local/tmp/flutter_gemma_test/; other desktop and
/// iOS: app Documents.
///
/// Run: cd example && flutter test integration_test/sampler_baking_2080_test.dart -d <device>
///   [--dart-define=LATCH_BACKEND=gpu]
/// Android on DDP: the app + androidTest APKs under `am instrument`
/// (.claude/skills/ddp-device-test).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _modelFile = 'gemma-4-E2B-it.litertlm';

const _backendName = String.fromEnvironment(
  'LATCH_BACKEND',
  defaultValue: 'cpu',
);
final _backend = PreferredBackend.values.byName(_backendName);

const _prompt =
    'Invent a name for a cosy coffee shop. Answer with the name only.';

/// One generation on [model] with the given sampler params.
Future<String> _gen(
  InferenceModel model, {
  required int topK,
  required double temperature,
  required int randomSeed,
}) async {
  final session = await model.openSession(
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

Future<InferenceModel> _engine() async {
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: _backend,
  );
  expect(
    model.activeBackend,
    _backend,
    reason:
        'asked for $_backendName, the engine runs on ${model.activeBackend}',
  );
  return model;
}

Future<void>? _installed;

/// Installs the model once. Called first thing in the test body, not from a
/// setUpAll: a setUpAll that throws is reported as a pass under `flutter
/// drive` and `am instrument` (AGENTS.md Rule 6b).
Future<void> _install() => _installed ??= () async {
  await registerTestEngines();
  final path = await stagedModelPath(_modelFile);
  expect(
    path,
    isNotNull,
    reason:
        'stage $_modelFile; macOS: ~/models (container Documents fallback); '
        'Android: /data/local/tmp/flutter_gemma_test/; other desktop and iOS: '
        'app Documents',
  );
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
}();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#2080 — later sessions must honour their own sampler params '
      '($_backendName)', (_) async {
    await _install();
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

    final verdict = g2 != g
        ? 'INCONCLUSIVE (greedy is not reproducible: G2 != G)'
        : z == g
        ? 'INCONCLUSIVE (the fresh stochastic engine also gave G)'
        : x == g && y == g
        ? 'PRESENT (X == Y == G: the first generation baked the sampler)'
        : x == g || y == g
        ? 'MIXED (one later session equals G)'
        : 'FIXED (later sessions honour their own sampler)';
    // ignore: avoid_print
    print(
      '[#2080] backend=$_backendName\n'
      '[#2080] G (greedy, engine A first)="$g"\n'
      '[#2080] X (stoch, same engine)="$x"\n'
      '[#2080] Y (stoch, same engine)="$y"\n'
      '[#2080] Z (stoch, fresh engine B)="$z"\n'
      '[#2080] G2(greedy, fresh engine C)="$g2"\n'
      '[#2080] VERDICT: $verdict',
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
          'FAIL = #2080 still reproduces on $_backendName: the engine stayed '
          'locked to what the first (greedy) generation baked',
    );
    expect(y, isNot(equals(g)), reason: 'same, second stochastic session');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
