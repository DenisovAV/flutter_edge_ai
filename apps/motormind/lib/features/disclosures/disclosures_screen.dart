import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

/// The permanent long-form disclosures (Q18), reachable from every screen.
class DisclosuresScreen extends StatelessWidget {
  const DisclosuresScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Disclosures')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final d in Disclosures.all) ...[
            Text(d.short, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(d.long, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 20),
          ],
          Text('Disclosure version ${Disclosures.gateVersion}', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
