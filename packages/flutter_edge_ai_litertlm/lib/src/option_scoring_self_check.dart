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
// token identically on 0.18.0 and differently with the fix. Two checks of our
// own follow: a prompt that differs early must score differently (so
// "identical" cannot mean scores that ignore the prompt), and the picked mode
// must score targets in one run, in either order, as each scores alone (mode
// `once` is exact after a rewind only through how 0.18.0's step, rollback and
// rewind interact; a LiteRT-LM that changes them is refused here, not trusted
// silently). Pure Dart over the scorer's calls, so it is unit-tested without
// an engine.

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

/// The pair's first prompt with its instruction's first word changed: an
/// early difference every engine must see, whichever mode it needs.
const liteRtLmSelfCheckControlPrompt =
    '<start_of_turn>user\nReply with one word.<end_of_turn>\n'
    '<start_of_turn>model\n';

/// Picks the [LiteRtLmScoringMode] for an engine, from the first three
/// [targets], the first token of each that tokenises back to itself, each
/// scored after both prompts of the pair, twice; then checks the mode it
/// picked the way a decision uses it.
///
/// [scoreOneToken] scores one token right after a fresh prefill of a prompt,
/// with nothing prefilled again. [scoreInMode] scores one-token targets after
/// a prompt in one run, as a decision does in that mode: each target after a
/// rewind but the first.
///
/// Throws `DeciderUnsupportedException` when there is nothing to compare,
/// when the two runs of one prompt differ (an engine whose scores are not
/// repeatable cannot be told apart), when a score is not a log-probability,
/// when some comparisons are identical and others are not, when a prompt
/// that differs early scores the same (the scores do not see the prompt),
/// and when targets scored in one run, in either order, do not score as each
/// does alone (rewinding between targets changes them).
Future<LiteRtLmScoringMode> liteRtLmScoringSelfCheck({
  required List<String> targets,
  required Future<List<int>> Function(String text) tokenize,
  required Future<String> Function(List<int> ids) detokenize,
  required Future<double> Function(String prompt, String token) scoreOneToken,
  required Future<List<double>> Function(
    LiteRtLmScoringMode mode,
    String prompt,
    List<String> tokens,
  )
  scoreInMode,
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
  var controlDiffers = false;
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
    final control = await scoreOneToken(liteRtLmSelfCheckControlPrompt, z);
    if (control != first[0]) controlDiffers = true;
  }
  // Without this, "identical" below would also be what an engine gives
  // whose scores do not depend on the prompt at all.
  if (!controlDiffers) {
    throw const DeciderUnsupportedException(
      'The scoring self-check scored its probes identically after two prompts '
      'that differ in their first words: this engine\'s scores do not see the '
      'prompt.',
    );
  }
  final most = diffs.reduce(math.max);
  final least = diffs.reduce(math.min);
  final LiteRtLmScoringMode mode;
  if (most == 0) {
    mode = LiteRtLmScoringMode.once;
  } else if (least > 0) {
    mode = LiteRtLmScoringMode.plain;
  } else {
    throw DeciderUnsupportedException(
      'The scoring self-check is mixed: of ${diffs.length} comparisons some '
      'scored identically and some did not (largest difference $most). This '
      'LiteRT-LM scores in a way nobody has measured.',
    );
  }
  // The mode as a decision uses it: every target after the first is scored
  // after a rewind, which 0.18.0 makes exact only through how its step, its
  // rollback and its rewind interact. A LiteRT-LM that changes any of them
  // would score every option after the first wrongly, with no error.
  final run = probes.length >= 2 ? probes : [probes.single, probes.single];
  final alone = [
    for (final z in run) (await scoreInMode(mode, a, [z])).single,
  ];
  final forward = await scoreInMode(mode, a, run);
  final backward = await scoreInMode(mode, a, run.reversed.toList());
  for (var i = 0; i < run.length; i++) {
    if (forward[i] != alone[i] || backward[run.length - 1 - i] != alone[i]) {
      throw DeciderUnsupportedException(
        'The scoring self-check scored "${run[i]}" ${alone[i]} alone, '
        '${forward[i]} and ${backward[run.length - 1 - i]} in one run with '
        'other targets (mode ${mode.name}): on this LiteRT-LM rewinding '
        'between targets changes their scores, so a decision\'s options '
        'cannot be scored exactly.',
      );
    }
  }
  return mode;
}
