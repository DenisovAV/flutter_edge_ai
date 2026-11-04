// LiteRT-LM's scoring self-check with the engine scripted. On a real engine
// it runs in example/integration_test/litertlm_inference_decider_test.dart,
// where LiteRT-LM 0.19 must pass it (#3561 fixed upstream).
// ignore_for_file: experimental_member_use
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/option_scoring_self_check.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_test/flutter_test.dart';

final _user =
    '${liteRtLmSelfCheckPrompt.substring(0, liteRtLmSelfCheckPrompt.length - 6)}'
    'user\n';

/// Each probe's own score, so that a mix-up between the targets of a run and
/// the scores of their runs alone is visible.
const _base = {'sad': -1.2, 'joy': -2.3, 'love': -0.9};

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
  /// script can vary between repeats. By default an engine with the #3561
  /// fix: the pair's two prompts, which differ in their second-to-last
  /// token, score differently, and so does the control prompt, which
  /// differs early, as on every engine.
  double Function(String prompt, String token, int call) score =
      (prompt, token, call) =>
          (_base[token] ?? -1.5) -
          (prompt == liteRtLmSelfCheckControlPrompt ? 0.2 : 0) -
          (prompt == _user ? 0.3 : 0);
  int calls = 0;

  /// The scores of one run of [tokens] after [prompt]: by default each as it
  /// scores alone, which is what an exact rewind gives.
  List<double> Function(String prompt, List<String> tokens) inRun =
      (prompt, tokens) => [for (final t in tokens) _base[t] ?? -1.5];
  PreferredBackend? backend = PreferredBackend.cpu;
  final runs = <List<String>>[];
  final runPrompts = <String>[];

  Future<void> check([List<String> targets = const ['sad', 'joy', 'love']]) =>
      liteRtLmScoringSelfCheck(
        backend: backend,
        targets: targets,
        tokenize: (text) async => tokens[text] ?? const [],
        detokenize: (ids) async => ids.map((id) => pieces[id] ?? '?').join(),
        scoreOneToken: (prompt, token) async => score(prompt, token, calls++),
        scoreInRun: (prompt, tokens) async {
          runs.add(tokens);
          runPrompts.add(prompt);
          return inRun(prompt, tokens);
        },
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
  group('the self-check runs in debug and profile builds only', () {
    test('a release build scores without running it', () async {
      var checks = 0;
      await liteRtLmScoringChecked(
        releaseMode: true,
        selfCheck: () async => checks++,
      );
      expect(checks, 0);
    });

    test('a debug or profile build runs it', () async {
      var checks = 0;
      await liteRtLmScoringChecked(
        releaseMode: false,
        selfCheck: () async => checks++,
      );
      expect(checks, 1);
    });

    test('a debug build passes the check\'s refusal on', () async {
      final engine = _Engine()
        ..score = (prompt, token, call) => -1.5 - call * 1e-6;
      await expectLater(
        liteRtLmScoringChecked(releaseMode: false, selfCheck: engine.check),
        _refusing('not repeatable'),
      );
    });

    test('this test run is not a release build, so the check runs', () {
      // The engine passes kReleaseMode; flutter test is never release.
      expect(kReleaseMode, isFalse);
    });
  });

  group('a refusal that depends on the engine\'s arithmetic names the '
      'backend', () {
    final cases = <String, _Engine Function()>{
      'not repeatable': () =>
          _Engine()..score = (prompt, token, call) => -1.5 - call * 1e-6,
      'mixed': () => _Engine()
        ..score = (prompt, token, _) =>
            prompt == liteRtLmSelfCheckPrompt || token == 'sad' ? -1.5 : -2.0,
      'rewinding': () => _Engine()
        ..inRun = (prompt, tokens) => [
          for (var i = 0; i < tokens.length; i++) i == 0 ? -1.5 : -1.6,
        ],
      '#3561': () =>
          _Engine()
            ..score = (prompt, token, _) =>
                prompt == liteRtLmSelfCheckControlPrompt ? -1.7 : -1.5,
    };
    for (final MapEntry(key: says, value: make) in cases.entries) {
      test('$says, on the GPU: points to the CPU', () async {
        final engine = make()..backend = PreferredBackend.gpu;
        await expectLater(
          engine.check(),
          throwsA(
            isA<DeciderUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains(says),
                contains('The check ran on the GPU'),
                contains('preferredBackend: PreferredBackend.cpu'),
              ),
            ),
          ),
        );
      });
      test('$says, on the CPU: names the CPU, no advice', () async {
        final engine = make();
        await expectLater(
          engine.check(),
          throwsA(
            isA<DeciderUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('The check ran on the CPU.'),
                isNot(contains('preferredBackend')),
              ),
            ),
          ),
        );
      });
    }
  });

  test('identical scores on both prompts are refused: the 0.18 scoring '
      '(LiteRT-LM #3561), no workaround any more', () async {
    final engine = _Engine()
      ..score = (prompt, token, _) =>
          prompt == liteRtLmSelfCheckControlPrompt ? -1.7 : -1.5;
    await expectLater(
      engine.check(),
      throwsA(
        isA<DeciderUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('#3561'), contains('older than this package')),
        ),
      ),
    );
    expect(engine.runs, isEmpty);
  });

  test('different scores pass (an engine with the #3561 fix), and the runs '
      'that check the rewinds are after the pair\'s prompt', () async {
    final engine = _Engine();
    await engine.check();
    // Three probes, two repeats, two prompts, and the control prompt.
    expect(engine.calls, 15);
    // Then as a decision scores: each probe alone, all three in one run, and
    // in the other order.
    expect(engine.runs, [
      ['sad'],
      ['joy'],
      ['love'],
      ['sad', 'joy', 'love'],
      ['love', 'joy', 'sad'],
    ]);
    expect(engine.runPrompts.toSet(), {liteRtLmSelfCheckPrompt});
  });

  test('a control score that is not a log-probability is refused', () async {
    final engine = _Engine()
      ..score = (prompt, token, _) =>
          prompt == liteRtLmSelfCheckControlPrompt ? double.nan : -1.5;
    await expectLater(engine.check(), _refusing('control'));
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
    'no probe that tokenises back to itself: refused, not taken for a pass',
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
    expect(engine.calls, 15);
  });

  test('a prompt that differs early but scores the same is refused: the '
      'scores do not see the prompt', () async {
    final engine = _Engine()..score = (prompt, token, call) => -1.5;
    await expectLater(engine.check(), _refusing('do not see the prompt'));
    expect(engine.runs, isEmpty);
  });

  test(
    'a target scored after a rewind that differs from alone is refused',
    () async {
      final engine = _Engine()
        ..inRun = (prompt, tokens) => [
          for (var i = 0; i < tokens.length; i++) i == 0 ? -1.5 : -1.6,
        ];
      await expectLater(engine.check(), _refusing('rewinding'));
    },
  );

  test('the other order alone differing is refused too', () async {
    final engine = _Engine()
      ..inRun = (prompt, tokens) => [
        for (final t in tokens)
          tokens.first == 'love' && t == 'sad' ? -1.9 : -1.5,
      ];
    await expectLater(engine.check(), _refusing('rewinding'));
  });

  test(
    'one probe is run twice in one run, so a rewind is still checked',
    () async {
      final engine = _Engine();
      await engine.check(['sad']);
      expect(engine.runs, [
        ['sad'],
        ['sad'],
        ['sad', 'sad'],
        ['sad', 'sad'],
      ]);
    },
  );
}
