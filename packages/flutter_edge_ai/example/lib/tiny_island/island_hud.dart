import 'dart:async';

import 'package:flutter/material.dart';

import 'island_decider.dart';
import 'tiny_island_view_model.dart';

const _muted = TextStyle(color: Colors.white70, fontSize: 12.5);
const _panel = Color(0xE01a3a5c);

/// "36 ms", or "0.42 ms" under a millisecond.
String formatIslandDuration(Duration d) {
  final ms = d.inMicroseconds / 1000;
  return ms >= 10
      ? '${ms.round()} ms'
      : '${ms.toStringAsFixed(ms >= 1 ? 1 : 2)} ms';
}

/// Why the Decider abstained, in words.
String describeIslandAbstain(IslandDecision decision) {
  final best = decision.ranked.firstOrNull;
  return switch (decision.abstainReason) {
    IslandAbstainReason.outOfScope =>
      'Nothing on the island matches: the best, ${best?.id}, scored '
          '${best?.score.toStringAsFixed(3)}, under the '
          '${decision.threshold?.toStringAsFixed(3)} it needs.',
    IslandAbstainReason.ambiguous =>
      'Too close to call: ${best?.id} and ${decision.ranked.elementAtOrNull(1)?.id} '
          'are ${decision.margin.toStringAsFixed(3)} apart.',
    null => '',
  };
}

/// The line under the HUD: how many options, how long.
String describeIslandTiming(IslandDecision decision) {
  final verb = decision.abstained ? 'Weighed' : 'Chosen among';
  return '$verb ${decision.optionCount} actions in '
      '${formatIslandDuration(decision.totalTime)} '
      '(embed ${formatIslandDuration(decision.embedTime)} + score '
      '${formatIslandDuration(decision.scoreTime)})';
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
    final decision = turn?.decision;
    final children = <Widget>[];
    if (turn == null) {
      children.add(
        Text(
          'Tell the character what to do, in your own words. The Decider '
          'picks one of ${vm.optionCount} actions, or shrugs.',
          style: _muted,
        ),
      );
    } else {
      children.add(
        Text(
          '"${turn.request}"',
          key: const Key('tiny-island-request'),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
      if (vm.deciding && decision == null) {
        children.add(const Text('Deciding...', style: _muted));
      }
      if (decision != null) {
        final best = decision.ranked.first;
        if (decision.choice case final choice?) {
          children.add(
            Text.rich(
              key: const Key('tiny-island-choice'),
              TextSpan(
                children: [
                  TextSpan(
                    text: choice,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.lightGreenAccent,
                    ),
                  ),
                  TextSpan(text: '  ${_score(best)}', style: _muted),
                ],
              ),
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
                fontSize: 16,
                color: Colors.amberAccent,
              ),
            ),
          );
          children.add(
            Text(
              describeIslandAbstain(decision),
              key: const Key('tiny-island-abstain-reason'),
              style: _muted,
            ),
          );
        }
        final others = decision.abstained
            ? decision.ranked.take(3)
            : decision.ranked.skip(1).take(3);
        if (others.isNotEmpty) {
          children.add(const SizedBox(height: 4));
          children.add(
            Text(
              decision.abstained ? 'Closest:' : 'Runners-up:',
              style: _muted,
            ),
          );
          for (final (i, option) in others.indexed) {
            children.add(
              Text(
                '${option.id}  ${_score(option)}',
                key: Key('tiny-island-alternative-$i'),
                style: const TextStyle(fontSize: 12.5),
              ),
            );
          }
        }
        children.add(const SizedBox(height: 4));
        children.add(
          Text(
            describeIslandTiming(decision),
            key: const Key('tiny-island-timing'),
            style: _muted,
          ),
        );
      }
      // The island's last remark, which may be about an earlier request
      // still playing when this one was decided.
      if (vm.lastNote case final note?) {
        children.add(
          Text(
            note,
            key: const Key('tiny-island-note'),
            style: const TextStyle(color: Colors.amberAccent, fontSize: 12.5),
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
            style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
          ),
        );
      }
    }
    return Container(
      key: const Key('tiny-island-hud'),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(10),
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

  static String _score(IslandRankedOption option) {
    final p = option.probability;
    final percent = switch (p) {
      null => '',
      < 0.001 => ' · <0.1%',
      < 0.1 => ' · ${(p * 100).toStringAsFixed(1)}%',
      _ => ' · ${(p * 100).toStringAsFixed(0)}%',
    };
    return '${option.score.toStringAsFixed(3)}$percent';
  }
}

/// The Decider itself: which model, on what, how many actions; or what it is
/// doing, or why it cannot run.
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
            'Teaching the Decider ${vm.catalog.length} actions: embedded '
            '${vm.prepared} of ${vm.preparedOf} phrasings (once per model)',
            style: _muted,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: vm.preparedOf == 0 ? null : vm.prepared / vm.preparedOf,
          ),
        ],
      ),
      TinyIslandStatus.ready => Text(
        'Decider: ${vm.deciderName} · backend ${vm.backend ?? 'unknown'} · '
        '${vm.optionCount} actions'
        '${vm.prepareTime == null ? '' : ' · ready in ${formatIslandDuration(vm.prepareTime!)}'}',
        key: const Key('tiny-island-backend'),
        style: _muted,
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
