import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import 'chat_service.dart';

String _money(Object? v) {
  if (v is! num) return v?.toString() ?? '';
  final s = v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '${v < 0 ? '-' : ''}\$$intPart.${parts[1]}';
}

String _label(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// Renders whatever the model presented. Result components read ONLY from
/// the tool result (ADR 0002); interaction components read from props.
/// First cut: a generic outputs card with highlights; dedicated widgets per
/// component follow (VA-11.1.2).
class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.shown, required this.onChoice});

  final ShownComponent shown;
  final void Function(String label) onChoice;

  @override
  Widget build(BuildContext context) {
    final req = shown.request;
    return switch (req.component.id) {
      'choice' || 'multi_choice' => _ChoiceCard(request: req, onChoice: onChoice),
      'input_form' => _FormCard(request: req, onSubmit: onChoice),
      _ => _OutputsCard(shown: shown),
    };
  }
}

class _OutputsCard extends StatelessWidget {
  const _OutputsCard({required this.shown});

  final ShownComponent shown;

  static const _moneyKeys = {
    'monthlyPayment',
    'amountFinanced',
    'cashDueAtSigning',
    'totalOfPayments',
    'financeCharge',
    'totalCost',
    'salesTax',
    'tradeEquityApplied',
    'negativeEquityFinanced',
    'equity',
    'shortfall',
    'suggestedMaxPayment',
    'max_amount_financed',
    'depreciation',
    'fuelOrEnergy',
    'insurance',
    'maintenance',
    'taxesAndFees',
    'total',
    'basePayment',
    'monthlyTax',
    'depreciationCharge',
    'rentCharge',
    'adjustedCapCost',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = shown.request;
    final result = shown.result?.result;
    final outputs = (result?['outputs'] as Map?)?.cast<String, Object?>() ?? const {};
    final assumptions = (result?['assumptions'] as List?)?.cast<Map>() ?? const [];
    final highlights = req.highlights.toSet();

    return Card(
      key: Key('card-${req.component.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(req.title ?? _label(req.component.id), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final e in outputs.entries)
              if (e.value is num || e.value is String || e.value is bool)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(_label(e.key), style: theme.textTheme.bodyMedium)),
                      Text(
                        _moneyKeys.contains(e.key) ? _money(e.value) : e.value.toString(),
                        key: Key('out-${e.key}'),
                        style: highlights.contains(e.key)
                            ? theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              )
                            : theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
            if (assumptions.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Assumptions (${assumptions.length})',
                  style: theme.textTheme.labelLarge,
                ),
                children: [
                  for (final a in assumptions)
                    ListTile(
                      dense: true,
                      title: Text('${a['description']}'),
                      subtitle: Text('${a['value']} · ${a['source']} · as of ${a['asOf']}'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(Disclosures.estimatesOnly.short, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.request, required this.onChoice});

  final PresentRequest request;
  final void Function(String label) onChoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = (request.props['options'] as List?)?.cast<Map>() ?? const [];
    return Card(
      key: const Key('card-choice'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${request.props['question'] ?? request.title ?? ''}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in options)
                  ActionChip(
                    key: Key('choice-${o['id']}'),
                    label: Text('${o['label']}'),
                    onPressed: () => onChoice('${o['label']}'),
                  ),
                ActionChip(
                  key: const Key('choice-escape'),
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Something else'),
                  onPressed: () => onChoice('Something else; let me explain.'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FormCard extends StatefulWidget {
  const _FormCard({required this.request, required this.onSubmit});

  final PresentRequest request;
  final void Function(String text) onSubmit;

  @override
  State<_FormCard> createState() => _FormCardState();
}

class _FormCardState extends State<_FormCard> {
  final Map<String, TextEditingController> _controllers = {};

  List<Map> get _fields => (widget.request.props['fields'] as List?)?.cast<Map>() ?? const [];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('card-input_form'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.request.props['title'] ?? widget.request.title ?? 'A few details'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final f in _fields)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: TextField(
                  key: Key('field-${f['id']}'),
                  controller: _controllers.putIfAbsent('${f['id']}', TextEditingController.new),
                  keyboardType: f['type'] == 'text'
                      ? TextInputType.text
                      : const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '${f['label']}',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  key: const Key('form-submit'),
                  onPressed: () {
                    final parts = [
                      for (final f in _fields)
                        if ((_controllers['${f['id']}']?.text ?? '').trim().isNotEmpty)
                          '${f['label']}: ${_controllers['${f['id']}']!.text.trim()}',
                    ];
                    widget.onSubmit(parts.isEmpty ? 'I would rather explain.' : parts.join('; '));
                  },
                  child: const Text('Use these'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => widget.onSubmit('I would rather explain.'),
                  child: const Text('Something else'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
