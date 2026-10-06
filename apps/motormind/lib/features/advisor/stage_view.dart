import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_service.dart';
import '../chat/result_card.dart';
import 'stage.dart';

/// Renders the stage. Empty state is a template until the model-chosen
/// empty state exists (DD-R16).
class StageView extends ConsumerWidget {
  const StageView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(stageProvider);
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Center(
        key: const Key('stage-empty'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.directions_car_outlined, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                'What would a vehicle really cost you?',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Tell the advisor what you have in mind. Numbers show up here as you go.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const Key('stage'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        for (final s in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ResultCard(
              shown: s,
              onChoice: (id, label) => ref.read(chatServiceProvider.notifier).choose(id, label),
            ),
          ),
      ],
    );
  }
}

/// Mode-specific starters the app presents the moment a mode is chosen, so
/// the screen responds before the model has said a word (Q43, DD principle 3).
ShownComponent? starterFor(ShoppingMode mode) {
  final args = switch (mode) {
    ShoppingMode.practical || ShoppingMode.buying => {
      'component': 'input_form',
      'props': {
        'title': 'The numbers that matter most',
        'fields': [
          {'id': 'payment', 'label': 'Monthly payment you can live with (\$)', 'type': 'currency'},
          {'id': 'down', 'label': 'Cash down (\$)', 'type': 'currency'},
          {
            'id': 'credit',
            'label': 'Credit: excellent, good, fair, poor or rebuilding',
            'type': 'text',
          },
          {'id': 'term', 'label': 'Loan length in months (48, 60, 72)', 'type': 'number'},
        ],
      },
    },
    ShoppingMode.browsing || ShoppingMode.dreaming => {
      'component': 'choice',
      'props': {
        'question': 'What kind of vehicle are we talking about?',
        'options': [
          {'id': 'kind-suv', 'label': 'SUV'},
          {'id': 'kind-car', 'label': 'Sedan or hatchback'},
          {'id': 'kind-pickup', 'label': 'Pickup'},
          {'id': 'kind-van', 'label': 'Van or minivan'},
          {'id': 'kind-unsure', 'label': 'Not sure yet'},
        ],
      },
    },
  };
  final v = PresentRequest.validate(args, resultTool: null);
  return v.request == null ? null : ShownComponent(request: v.request!);
}
