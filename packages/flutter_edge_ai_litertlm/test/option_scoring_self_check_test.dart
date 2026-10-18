// LiteRT-LM's scoring self-check with the engine scripted. On a real engine
// it runs in example/integration_test/litertlm_inference_decider_test.dart,
// where LiteRT-LM 0.18.0 must pick `once`.
// ignore_for_file: experimental_member_use
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/option_scoring_self_check.dart';
import 'package:flutter_test/flutter_test.dart';

final _user =
    '${liteRtLmSelfCheckPrompt.substring(0, liteRtLmSelfCheckPrompt.length - 6)}'
    'user\n';

/// A tokenizer for the emotion pack's first three targets and the pair.
final class _Engine {
  final Map<String, List<int>> tokens = {
    'sad': [37918],
    'joy': [3672],
    'love': [21867],
    liteRtLmSelfCheckPrompt: [
      105,
      2364,
      107,
      7925,
      607,
      886,
      106,
      107,
      105,
      4368,
      107,
    ],
    _user: [105, 2364, 107, 7925, 607, 886, 106, 107, 105, 2364, 107],
  };
  final Map<int, String> pieces = {37918: 'sad', 3672: 'joy', 21867: 'love'};

  /// The score of one token after one prompt; the call count is passed so a
  /// script can vary between repeats.
  double Function(String prompt, String token, int call) score =
      (prompt, token, call) => -1.5;
  int calls = 0;

  Future<LiteRtLmScoringMode> check([
    List<String> targets = const ['sad', 'joy', 'love'],
  ]) => liteRtLmScoringSelfCheck(
    targets: targets,
    tokenize: (text) async => tokens[text] ?? const [],
    detokenize: (ids) async => ids.map((id) => pieces[id] ?? '?').join(),
    scoreOneToken: (prompt, token) async => score(prompt, token, calls++),
  );
}

Matcher _refusing(String says) => throwsA(
  isA<DeciderUnsupportedException>().having(
    (e) => e.message,
    'message',
    contains(says),
  ),
);

void main() {
  test(
    'identical scores on both prompts pick once (LiteRT-LM 0.18.0)',
    () async {
      final engine = _Engine();
      expect(await engine.check(), LiteRtLmScoringMode.once);
      // Three probes, two repeats, two prompts.
      expect(engine.calls, 12);
    },
  );

  test('different scores pick plain (an engine with the #3561 fix)', () async {
    final engine = _Engine()
      ..score = (prompt, token, _) =>
          prompt == liteRtLmSelfCheckPrompt ? -1.5 : -2.0;
    expect(await engine.check(), LiteRtLmScoringMode.plain);
  });

  test('a mix of identical and different scores is refused', () async {
    final engine = _Engine()
      ..score = (prompt, token, _) =>
          prompt == liteRtLmSelfCheckPrompt || token == 'sad' ? -1.5 : -2.0;
    await expectLater(engine.check(), _refusing('mixed'));
  });

  test('scores that differ between two runs of one prompt are refused, not '
      'taken for plain', () async {
    final engine = _Engine()
      ..score = (prompt, token, call) => -1.5 - call * 1e-6;
    await expectLater(engine.check(), _refusing('not repeatable'));
  });

  test('a score above 0 is refused: not a log-probability', () async {
    final engine = _Engine()..score = (prompt, token, call) => 0.0 + 1;
    await expectLater(engine.check(), _refusing('not a log-probability'));
  });

  test(
    'no probe that tokenises back to itself: refused, not taken for once',
    () async {
      final engine = _Engine();
      for (final id in [37918, 3672, 21867]) {
        engine.tokens[engine.pieces[id]!] = [id, id];
      }
      await expectLater(engine.check(), _refusing('nothing to compare'));
      expect(engine.calls, 0);
    },
  );

  test(
    'a pair that differs elsewhere than its second-to-last token: refused',
    () async {
      final engine = _Engine();
      engine.tokens[_user] = [
        105,
        2364,
        107,
        7925,
        607,
        886,
        106,
        107,
        105,
        2364,
        108,
      ];
      await expectLater(engine.check(), _refusing('nothing to compare'));
    },
  );

  test('only the first three targets are probed', () async {
    final engine = _Engine()..tokens['fear'] = [143355];
    engine.pieces[143355] = 'fear';
    await engine.check(['sad', 'joy', 'love', 'fear']);
    expect(engine.calls, 12);
  });
}
