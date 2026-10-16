// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show
        AbstainReason,
        AbstainSignalKind,
        DeciderAnswer,
        DeciderMethod,
        RankedOption,
        ScoreKind;

import 'tiny_island_view_model.dart';

const _muted = TextStyle(color: Colors.white70, fontSize: 11);
const _panel = Color(0xE01a3a5c);

/// "36 ms", or "0.42 ms" under a millisecond.
String formatIslandDuration(Duration d) {
  final ms = d.inMicroseconds / 1000;
  return ms >= 10
      ? '${ms.round()} ms'
      : '${ms.toStringAsFixed(ms >= 1 ? 1 : 2)} ms';
}

/// "36 s" from ten seconds on, else as [formatIslandDuration].
String formatIslandPrepareTime(Duration d) => d.inSeconds >= 10
    ? '${d.inSeconds} s'
    : d.inMilliseconds >= 1000
    ? '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s'
    : formatIslandDuration(d);

/// An option's score as what it is: a cosine (or log-probability) with its
/// kind, plus the probability only when the Decider's probabilities are
/// calibrated. A raw cosine is never shown as a percentage. [withKind]
/// false drops the kind's name, for the runners-up line under a choice that
/// already shows it.
String formatIslandScore(
  RankedOption option,
  ScoreKind kind, {
  bool withKind = true,
}) {
  final value = kind == ScoreKind.logprob
      ? option.score.toStringAsFixed(2)
      : option.score.toStringAsFixed(3);
  final name = switch (kind) {
    ScoreKind.cosine => 'cosine',
    ScoreKind.logprob => 'log p',
    _ => kind.name,
  };
  final score = withKind ? '$name $value' : value;
  final p = option.probability;
  if (p == null) return score;
  final percent = p < 0.001
      ? '<0.1%'
      : p < 0.1
      ? '${(p * 100).toStringAsFixed(1)}%'
      : '${(p * 100).toStringAsFixed(0)}%';
  return '$score · p $percent';
}

/// Why the Decider abstained, in words. Reads only the shared answer, so an
/// inference decider's answer (a probability signal, a "none of these"
/// option) reads as well as the embedding decider's.
String describeIslandAbstain(DeciderAnswer answer) {
  final best = answer.ranked.firstOrNull;
  final reason = answer.abstainReason;
  if (reason == AbstainReason.belowThreshold) {
    final signal = answer.provenance.abstainSignal;
    final threshold = answer.provenance.threshold;
    final closest = best == null ? '' : ', ${best.id},';
    if (answer.provenance.abstainSignalKind ==
        AbstainSignalKind.topProbability) {
      return 'Nothing on the island fits: the likeliest action$closest has '
          'p ${_percent(signal)}, under the ${_percent(threshold)} it needs.';
    }
    return 'Nothing on the island fits: the closest action$closest is at '
        'cosine ${signal?.toStringAsFixed(3) ?? '?'}, under the '
        '${threshold?.toStringAsFixed(3) ?? '?'} it needs.';
  }
  if (reason == AbstainReason.noneOption) {
    return 'Nothing on the island fits: the model chose '
        '"${best?.id ?? 'none of these'}".';
  }
  if (reason == AbstainReason.noCandidates) {
    return 'There were no actions to choose among.';
  }
  return 'Abstained (${reason?.name ?? 'no reason given'}).';
}

String _percent(double? p) =>
    p == null ? '?' : '${(p * 100).toStringAsFixed(0)}%';

/// The line under the HUD: how many actions, how long. The input's share is
/// an embedding, or an inference decider's prompt.
String describeIslandTiming(DeciderAnswer answer, int optionCount) {
  final verb = answer.choice == null ? 'Weighed' : 'Chosen among';
  final encode = answer.provenance.encodeTime;
  final score = answer.provenance.scoreTime;
  final stage = answer.provenance.method == DeciderMethod.optionScoring
      ? 'prompt'
      : 'embed';
  return '$verb $optionCount actions in '
      '${formatIslandDuration(encode + score)} '
      '($stage ${formatIslandDuration(encode)} + score '
      '${formatIslandDuration(score)})';
}

/// The Decider's last answer: what was asked, what it chose (or why it
/// abstained), the runners-up, and what it took.
class TinyIslandHud extends StatelessWidget {
  const TinyIslandHud({super.key, required this.viewModel});

  final TinyIslandViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final vm = viewModel;
    final turn = vm.lastTurn;
    final answer = turn?.answer;
    final children = <Widget>[];
    if (turn == null) {
      children.add(
        Text(
          'Tell the character what to do, in your own words'
          '${vm.voiceStatus == TinyIslandVoiceStatus.ready ? ' — type it, or hold the mic and say it' : ''}. '
          'The Decider picks one of ${vm.optionCount} actions, or shrugs.',
          style: _muted,
        ),
      );
    } else {
      children.add(
        Text(
          turn.spoken == null
              ? '"${turn.request}"'
              : 'You said it: ${turn.request}',
          key: const Key('tiny-island-request'),
          style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
        ),
      );
      if (vm.deciding && answer == null && turn.error == null) {
        children.add(const Text('Deciding...', style: _muted));
      }
      if (answer != null) {
        _addAnswer(children, answer, turn, vm.optionCount);
      }
      // The island's last remark, which may be about an earlier request
      // still playing when this one was decided.
      if (vm.lastNote case final note?) {
        children.add(
          Text(
            note,
            key: const Key('tiny-island-note'),
            style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
          ),
        );
      }
      if (vm.playing > 1) {
        children.add(
          Text(
            'The island is playing ${vm.playing} actions, in order.',
            key: const Key('tiny-island-queue'),
            style: _muted,
          ),
        );
      }
      if (turn.error case final error?) {
        children.add(
          SelectableText(
            error,
            key: const Key('tiny-island-turn-error'),
            style: const TextStyle(color: Colors.redAccent, fontSize: 11),
          ),
        );
      }
    }
    return Container(
      key: const Key('tiny-island-hud'),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  static void _addAnswer(
    List<Widget> children,
    DeciderAnswer answer,
    TinyIslandTurn turn,
    int optionCount,
  ) {
    // Empty when the Decider had no candidates (AbstainReason.noCandidates).
    final best = answer.ranked.firstOrNull;
    if (answer.choice case final choice?) {
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              choice,
              key: const Key('tiny-island-choice'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Colors.lightGreenAccent,
              ),
            ),
            if (best != null)
              Flexible(
                child: Text(
                  '  ${formatIslandScore(best, answer.scoreKind)}',
                  key: const Key('tiny-island-choice-score'),
                  style: _muted,
                ),
              ),
          ],
        ),
      );
      if (turn.action case final action?) {
        children.add(Text(action.description, style: _muted));
      }
    } else {
      children.add(
        const Text(
          'Abstained',
          key: Key('tiny-island-abstain'),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: Colors.amberAccent,
          ),
        ),
      );
      children.add(
        Text(
          describeIslandAbstain(answer),
          key: const Key('tiny-island-abstain-reason'),
          style: _muted,
        ),
      );
    }
    final others = answer.choice == null
        ? answer.ranked.take(3)
        : answer.ranked.skip(1).take(3);
    if (others.isNotEmpty) {
      children.add(const SizedBox(height: 2));
      // One line on a phone: the HUD sits over the scene.
      children.add(
        Wrap(
          spacing: 8,
          children: [
            Text(
              answer.choice == null ? 'Closest:' : 'Runners-up:',
              style: _muted,
            ),
            for (final (i, option) in others.indexed)
              Text(
                '${option.id} '
                '${formatIslandScore(option, answer.scoreKind, withKind: false)}',
                key: Key('tiny-island-alternative-$i'),
                style: const TextStyle(fontSize: 11),
              ),
          ],
        ),
      );
    }
    children.add(const SizedBox(height: 2));
    children.add(
      Text(
        describeIslandTiming(answer, optionCount),
        key: const Key('tiny-island-timing'),
        style: _muted,
      ),
    );
  }
}

/// The Decider itself: which model, on what, how many actions, how it was
/// calibrated and prepared; or what it is doing, or why it cannot run.
/// The status bar's line about spoken requests; null before the active
/// bundle is read.
String? _voiceLine(TinyIslandViewModel vm) => switch (vm.voiceStatus) {
  TinyIslandVoiceStatus.preparing =>
    'Preparing the Decider for spoken requests: embedded '
        '${vm.voicePrepared} of ${vm.voicePreparedOf} texts',
  TinyIslandVoiceStatus.ready =>
    'Voice: plain audio, no transcript · ${vm.voiceCalibrationLabel}'
        '${vm.voiceNote == null ? '' : ' · ${vm.voiceNote}'}',
  TinyIslandVoiceStatus.off || TinyIslandVoiceStatus.failed =>
    vm.voiceNote == null ? null : 'Voice off: ${vm.voiceNote}',
};

class TinyIslandStatusBar extends StatelessWidget {
  const TinyIslandStatusBar({
    super.key,
    required this.viewModel,
    required this.onChooseModel,
  });

  final TinyIslandViewModel viewModel;
  final VoidCallback onChooseModel;

  @override
  Widget build(BuildContext context) {
    final vm = viewModel;
    final Widget body = switch (vm.status) {
      TinyIslandStatus.loading => Text(
        'Loading ${vm.embedderName ?? 'the active embedding model'}...',
        style: _muted,
      ),
      TinyIslandStatus.preparing => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Preparing the Decider for ${vm.catalog.length} actions: '
            'embedded ${vm.prepared} of ${vm.preparedOf} texts (kept in '
            '${vm.storeWhere} for the next visit)',
            key: const Key('tiny-island-preparing'),
            style: _muted,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: vm.preparedOf == 0 ? null : vm.prepared / vm.preparedOf,
          ),
        ],
      ),
      TinyIslandStatus.ready => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Decider: ${vm.embedderName} · backend ${vm.backend ?? 'unknown'} · '
            '${vm.optionCount} actions · ${vm.calibrationLabel}'
            '${vm.prepareNote == null ? '' : ' · ${vm.prepareNote}'}'
            '${vm.prepareTime == null ? '' : ' · ready in ${formatIslandPrepareTime(vm.prepareTime!)}'}',
            key: const Key('tiny-island-backend'),
            style: _muted,
          ),
          if (_voiceLine(vm) case final line?) ...[
            const SizedBox(height: 2),
            Text(line, key: const Key('tiny-island-voice'), style: _muted),
          ],
          if (vm.voiceStatus == TinyIslandVoiceStatus.preparing) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: vm.voicePreparedOf == 0
                  ? null
                  : vm.voicePrepared / vm.voicePreparedOf,
            ),
          ],
        ],
      ),
      TinyIslandStatus.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            vm.error ?? 'The Decider did not start.',
            key: const Key('tiny-island-error'),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              if (vm.suggestModelList)
                FilledButton(
                  key: const Key('tiny-island-choose-model'),
                  onPressed: onChooseModel,
                  child: const Text('Choose a model'),
                ),
              OutlinedButton(
                key: const Key('tiny-island-retry'),
                // open() keeps any failure in the view model's state.
                onPressed: () => unawaited(vm.open()),
                child: const Text('Try again'),
              ),
            ],
          ),
        ],
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: vm.status == TinyIslandStatus.failed
          ? Colors.red.shade900
          : const Color(0xFF14304f),
      child: body,
    );
  }
}
