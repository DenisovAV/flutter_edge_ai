import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browser/browser_pane.dart';
import '../chat/chat_service.dart';
import '../chat/result_card.dart';
import '../listings/listing_cards.dart';
import 'stage.dart';

/// The web pane is injectable so widget tests do not need a platform webview.
final webPaneBuilderProvider = Provider<Widget Function()>(
  (ref) =>
      () => const BrowserPane(),
);

/// Renders the stage: a thin mode row (Web | Cards), then either the browser
/// pane or the focused card with the others as chips.
class StageView extends ConsumerWidget {
  const StageView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = ref.watch(stageProvider);
    final hasCards = stage.cards.isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              SegmentedButton<StageMode>(
                key: const Key('stage-mode'),
                segments: [
                  const ButtonSegment(
                    value: StageMode.web,
                    icon: Icon(Icons.public, size: 16),
                    label: Text('Web'),
                  ),
                  ButtonSegment(
                    value: StageMode.cards,
                    icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
                    label: Text(hasCards ? 'Cards (${stage.cards.length})' : 'Cards'),
                    enabled: hasCards,
                  ),
                ],
                selected: {
                  stage.mode == StageMode.cards && hasCards ? StageMode.cards : StageMode.web,
                },
                onSelectionChanged: (s) => ref.read(stageProvider.notifier).setMode(s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        Expanded(
          child: stage.mode == StageMode.cards && hasCards
              ? _Cards(stage: stage)
              : ref.watch(webPaneBuilderProvider)(),
        ),
      ],
    );
  }
}

class _Cards extends ConsumerStatefulWidget {
  const _Cards({required this.stage});
  final StageState stage;

  @override
  ConsumerState<_Cards> createState() => _CardsState();
}

class _CardsState extends ConsumerState<_Cards> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = widget.stage;
    final focused = stage.focused!;
    return Column(
      key: const Key('stage'),
      children: [
        if (stage.cards.length > 1)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (var i = 0; i < stage.cards.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                    child: ChoiceChip(
                      key: Key('stage-chip-$i'),
                      label: Text(cardSummary(stage.cards[i])),
                      selected: i == stage.focus.clamp(0, stage.cards.length - 1),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => ref.read(stageProvider.notifier).focusCard(i),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ScrollCut(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: ResultCard(
                shown: focused,
                onChoice: (id, label) =>
                    ref.read(chatServiceProvider.notifier).choose(id, label, source: focused),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One-line label for a card chip.
String cardSummary(ShownComponent s) {
  final o = outputsOf(s.result);
  return switch (s.request.component.id) {
    'payment_summary' ||
    'payment_breakdown' => 'Payment ${money(o['monthlyPayment'], cents: false)}/mo',
    'trade_equity_card' => 'Trade ${money(o['equity'], cents: false)}',
    'affordability_gauge' => 'Affordability',
    'vehicle_card' => 'Listings',
    'page_extract' => 'Page',
    'input_form' => s.request.props['title']?.toString() ?? 'Form',
    'choice' || 'multi_choice' => 'Question',
    _ => labelFor(s.request.component.id),
  };
}
