import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/router.dart';
import 'disclosures_notifier.dart';

/// The short-form gate: one sentence per disclosure, a link to the full
/// text, and an acknowledgement. Wording comes only from `Disclosures`.
class DisclosureGateScreen extends ConsumerWidget {
  const DisclosureGateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text(appName, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'A tool for understanding what a vehicle would cost you. Before you start:',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    for (final d in Disclosures.all)
                      ListTile(
                        key: ValueKey('disclosure-${d.key}'),
                        leading: const Icon(Icons.info_outline),
                        title: Text(d.short),
                        dense: true,
                      ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('gate-read-full'),
                onPressed: () => context.push(Routes.disclosures),
                child: const Text('Read the full disclosures'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('gate-acknowledge'),
                onPressed: () async {
                  await ref.read(disclosuresAcknowledgedProvider.notifier).acknowledge();
                  if (context.mounted) context.go(Routes.home);
                },
                child: const Text('I understand'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
