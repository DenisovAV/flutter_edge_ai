// Whether this LiteRT-LM scores a target right after a prefill correctly,
// found out once per loaded model before its first decision. LiteRT-LM 0.18.0
// scored it without the prompt's second-to-last token (#3561); this package
// worked around that with a mode `once` that prefilled the prompt's last token
// again. 0.19.0 carries the fix (upstream b8b3131), the pinned native build is
// 0.19, and the workaround is gone: a decision is scored right after its
// prefill, and an engine that still scores the 0.18 way is refused.
//
// The check is litetune's own (`decision_scripts` ENGINE_SCRIPT, 0.5.0): two
// prompts that differ only in their second-to-last token score each probe
// token identically on 0.18.0 and differently with the fix. Two checks of our
// own follow: a prompt that differs early must score differently (so a
// difference cannot come from scores that ignore the prompt), and targets
// scored in one run, in either order, must score as each scores alone (each
// target after the first is scored after a rewind; a LiteRT-LM whose rewind
// changes them is refused here, not trusted silently). Pure Dart over the
// scorer's calls, so it is unit-tested without an engine.

// The decider SPI (DeciderUnsupportedException) is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart';

/// Runs [selfCheck] in debug and profile builds, so a developer's run on the
/// target hardware checks the engine; skips it in a release build
/// ([releaseMode]), and its cost at the first decision with it. The pinned
/// native build passed it on every engine measured (LiteRT-LM 0.19 on the
/// CPU, Apple Metal, Adreno 830, Tesla T4 and Arc B390).
Future<void> liteRtLmScoringChecked({
  required bool releaseMode,
  required Future<void> Function() selfCheck,
}) => releaseMode ? Future.value() : selfCheck();

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

/// Checks that an engine scores right after a prefill with the whole prompt,
/// from the first three [targets], the first token of each that tokenises
/// back to itself, each scored after both prompts of the pair, twice; then
/// checks targets scored the way a decision scores them.
///
/// [scoreOneToken] scores one token right after a fresh prefill of a prompt.
/// [scoreInRun] scores one-token targets after a prompt in one run, as a
/// decision does: each target after a rewind but the first.
///
/// Throws `DeciderUnsupportedException` when there is nothing to compare,
/// when the two runs of one prompt differ (an engine whose scores are not
/// repeatable cannot be told apart), when a score is not a log-probability,
/// when every comparison of the pair is identical (the 0.18 scoring, #3561),
/// when some are identical and others are not, when a prompt that differs
/// early scores the same (the scores do not see the prompt), and when
/// targets scored in one run, in either order, do not score as each does
/// alone (rewinding between targets changes them). The refusals that depend
/// on the engine's arithmetic name [backend], the one the check ran on, and
/// on the GPU point to the CPU.
Future<void> liteRtLmScoringSelfCheck({
  required PreferredBackend? backend,
  required List<String> targets,
  required Future<List<int>> Function(String text) tokenize,
  required Future<String> Function(List<int> ids) detokenize,
  required Future<double> Function(String prompt, String token) scoreOneToken,
  required Future<List<double>> Function(String prompt, List<String> tokens)
  scoreInRun,
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
      'Without it this LiteRT-LM\'s scoring cannot be checked.',
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
        'so how it scores after a prefill cannot be told.${_ranOn(backend)}',
      );
    }
    for (var repeat = 0; repeat < 2; repeat++) {
      diffs.add((first[repeat] - second[repeat]).abs());
    }
    final control = await scoreOneToken(liteRtLmSelfCheckControlPrompt, z);
    if (!(control <= 1e-4)) {
      throw DeciderUnsupportedException(
        'The scoring self-check scored "$z" $control after its control '
        'prompt: not a log-probability.',
      );
    }
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
  if (most == 0) {
    throw DeciderUnsupportedException(
      'The scoring self-check scored its probes identically after two '
      'prompts that differ in their second-to-last token: this LiteRT-LM '
      'scores right after a prefill without that token (LiteRT-LM #3561, '
      'fixed in 0.19.0), so its options would be scored wrongly. A native '
      'library older than this package\'s is loaded.${_ranOn(backend)}',
    );
  }
  if (least == 0) {
    throw DeciderUnsupportedException(
      'The scoring self-check is mixed: of ${diffs.length} comparisons some '
      'scored identically and some did not (largest difference $most). This '
      'LiteRT-LM scores in a way nobody has measured.${_ranOn(backend)}',
    );
  }
  // As a decision scores: every target after the first after a rewind. A
  // LiteRT-LM whose rewind changes the step, the rollback or what the next
  // score reads would score every option after the first wrongly, with no
  // error.
  final run = probes.length >= 2 ? probes : [probes.single, probes.single];
  final alone = [
    for (final z in run) (await scoreInRun(a, [z])).single,
  ];
  final forward = await scoreInRun(a, run);
  final backward = await scoreInRun(a, run.reversed.toList());
  for (var i = 0; i < run.length; i++) {
    if (forward[i] != alone[i] || backward[run.length - 1 - i] != alone[i]) {
      throw DeciderUnsupportedException(
        'The scoring self-check scored "${run[i]}" ${alone[i]} alone, '
        '${forward[i]} and ${backward[run.length - 1 - i]} in one run with '
        'other targets: on this LiteRT-LM rewinding between targets changes '
        'their scores, so a decision\'s options cannot be scored '
        'exactly.${_ranOn(backend)}',
      );
    }
  }
}

/// Where the check ran, for a refusal; on the GPU, the way to the CPU.
String _ranOn(PreferredBackend? backend) => switch (backend) {
  PreferredBackend.gpu =>
    ' The check ran on the GPU; load the model with preferredBackend: '
        'PreferredBackend.cpu to score on the CPU.',
  PreferredBackend.cpu => ' The check ran on the CPU.',
  PreferredBackend.npu => ' The check ran on the NPU.',
  null => '',
};
