// How this LiteRT-LM scores right after a prefill, found out once per loaded
// model before its first decision. LiteRT-LM 0.18.0 scores a target right
// after a prefill without the prompt's second-to-last token (#3561, fixed
// upstream after 0.18.0): mode `once` prefills the prompt's last token again,
// once per decision, which gives the reference's scores there; mode `plain`
// does not, which is right on an engine with the fix. Each is wrong on the
// other engine, so the check picks, and refuses an engine it cannot tell.
//
// The check is litetune's own (`decision_scripts` ENGINE_SCRIPT, 0.5.0): two
// prompts that differ only in their second-to-last token score each probe
// token identically on 0.18.0 and differently with the fix. Pure Dart over the
// scorer's calls, so it is unit-tested without an engine.

// The decider SPI (DeciderUnsupportedException) is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart';

/// How a decision is scored on this engine; see the file comment.
enum LiteRtLmScoringMode {
  /// Prefill the prompt's last token again, once per decision (0.18.0).
  once,

  /// Score right after the prefill (an engine with the #3561 fix).
  plain,
}

/// The pair the check compares: the same text ending in the model turn's
/// opening and in the user turn's (`decision_scripts.FIXED`).
const liteRtLmSelfCheckPrompt =
    '<start_of_turn>user\nAnswer with one word.<end_of_turn>\n'
    '<start_of_turn>model\n';

/// Picks the [LiteRtLmScoringMode] for an engine, from the first token of
/// each of the first three [targets] that tokenises back to itself, each
/// scored after both prompts of the pair, twice.
///
/// [scoreOneToken] scores one token right after a fresh prefill of a prompt,
/// with nothing prefilled again. Throws `DeciderUnsupportedException` when
/// there is nothing to compare, when the two runs of one prompt differ (an
/// engine whose scores are not repeatable cannot be told apart), when a
/// score is not a log-probability, and when some comparisons are identical
/// and others are not.
Future<LiteRtLmScoringMode> liteRtLmScoringSelfCheck({
  required List<String> targets,
  required Future<List<int>> Function(String text) tokenize,
  required Future<String> Function(List<int> ids) detokenize,
  required Future<double> Function(String prompt, String token) scoreOneToken,
}) async {
  final probes = <String>[];
  for (final target in targets.take(3)) {
    final ids = await tokenize(target);
    if (ids.isEmpty) continue;
    final z = await detokenize([ids.first]);
    final back = await tokenize(z);
    if (back.length == 1 && back.single == ids.first) probes.add(z);
  }
  const a = liteRtLmSelfCheckPrompt;
  final b = '${a.substring(0, a.length - 'model\n'.length)}user\n';
  final ia = await tokenize(a);
  final ib = await tokenize(b);
  final differing = [
    for (var i = 0; i < math.min(ia.length, ib.length); i++)
      if (ia[i] != ib[i]) i,
  ];
  if (probes.isEmpty ||
      ia.length != ib.length ||
      differing.length != 1 ||
      differing.single != ia.length - 2) {
    throw const DeciderUnsupportedException(
      'The scoring self-check had nothing to compare: none of the first three '
      'options starts with a token that tokenises back to itself, or the '
      'check\'s two prompts do not differ in their second-to-last token alone. '
      'Without it this LiteRT-LM\'s scoring mode cannot be told.',
    );
  }
  final diffs = <double>[];
  for (final z in probes) {
    final first = <double>[];
    final second = <double>[];
    for (var repeat = 0; repeat < 2; repeat++) {
      first.add(await scoreOneToken(a, z));
      second.add(await scoreOneToken(b, z));
    }
    for (final score in [...first, ...second]) {
      if (!(score <= 1e-4)) {
        throw DeciderUnsupportedException(
          'The scoring self-check scored "$z" $score: not a log-probability.',
        );
      }
    }
    if (first[0] != first[1] || second[0] != second[1]) {
      throw DeciderUnsupportedException(
        'The scoring self-check scored "$z" twice after the same prompt and '
        'got $first and $second: this engine\'s scores are not repeatable, '
        'so how it scores after a prefill cannot be told.',
      );
    }
    for (var repeat = 0; repeat < 2; repeat++) {
      diffs.add((first[repeat] - second[repeat]).abs());
    }
  }
  final most = diffs.reduce(math.max);
  final least = diffs.reduce(math.min);
  if (most == 0) return LiteRtLmScoringMode.once;
  if (least > 0) return LiteRtLmScoringMode.plain;
  throw DeciderUnsupportedException(
    'The scoring self-check is mixed: of ${diffs.length} comparisons some '
    'scored identically and some did not (largest difference $most). This '
    'LiteRT-LM scores in a way nobody has measured.',
  );
}
