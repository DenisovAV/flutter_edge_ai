import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import 'chat_service.dart';

String money(Object? v, {bool cents = true}) {
  if (v is! num) return v?.toString() ?? '';
  final s = v.abs().toStringAsFixed(cents ? 2 : 0);
  final parts = s.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '${v < 0 ? '-' : ''}\$$intPart${cents ? '.${parts[1]}' : ''}';
}

String percent(Object? v) => v is num ? '${(v * 100).toStringAsFixed(2)}%' : '';

String labelFor(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

Map<String, Object?> outputsOf(ToolResult? r) =>
    (r?.result?['outputs'] as Map?)?.cast<String, Object?>() ?? const {};
Map<String, Object?> inputsOf(ToolResult? r) =>
    (r?.result?['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
List<Map> assumptionsOf(ToolResult? r) =>
    (r?.result?['assumptions'] as List?)?.cast<Map>() ?? const [];

/// Renders whatever was presented. Result components read ONLY from the tool
/// result (ADR 0002); interaction components read from props.
class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.shown, required this.onChoice});

  final ShownComponent shown;
  final void Function(String id, String label) onChoice;

  @override
  Widget build(BuildContext context) {
    final req = shown.request;
    return switch (req.component.id) {
      'choice' || 'multi_choice' => _ChoiceCard(shown: shown, onChoice: onChoice),
      'input_form' => _FormCard(shown: shown, onSubmit: (text) => onChoice('form', text)),
      'payment_summary' => _PaymentSummaryCard(shown: shown),
      'payment_breakdown' => _PaymentBreakdownCard(shown: shown),
      'trade_equity_card' => _TradeEquityCard(shown: shown),
      'vehicle_card' => _VehicleCard(shown: shown),
      'page_extract' => _PageExtractCard(shown: shown),
      _ => _OutputsCard(shown: shown),
    };
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.id,
    required this.title,
    required this.children,
    this.assumptions = const [],
  });

  final String id;
  final String title;
  final List<Widget> children;
  final List<Map> assumptions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('card-$id'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
            if (assumptions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Assumptions (${assumptions.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: [
                    for (final a in assumptions)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${a['description']}'),
                        subtitle: Text('${a['value']} · ${a['source']} · as of ${a['asOf']}'),
                      ),
                  ],
                ),
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

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.valueKey, this.emphasis = false, this.color});

  final String label;
  final String value;
  final String? valueKey;
  final bool emphasis;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            key: valueKey == null ? null : Key('out-$valueKey'),
            style: emphasis
                ? theme.textTheme.titleMedium?.copyWith(
                    color: color ?? theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  )
                : theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _PaymentSummaryCard extends StatelessWidget {
  const _PaymentSummaryCard({required this.shown});
  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final h = shown.request.highlights.toSet();
    return _CardShell(
      id: 'payment_summary',
      title: shown.request.title ?? 'Estimated payment',
      assumptions: assumptionsOf(shown.result),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              money(o['monthlyPayment']),
              key: const Key('out-monthlyPayment'),
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '/ month · ${i['termMonths']} months at ${percent(i['apr'])}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _Row(
          'Amount financed',
          money(o['amountFinanced']),
          valueKey: 'amountFinanced',
          emphasis: h.contains('amountFinanced'),
        ),
        _Row(
          'Cash due at signing',
          money(o['cashDueAtSigning']),
          valueKey: 'cashDueAtSigning',
          emphasis: h.contains('cashDueAtSigning'),
        ),
        if ((o['negativeEquityFinanced'] as num? ?? 0) > 0)
          _Row(
            'Negative equity rolled in',
            money(o['negativeEquityFinanced']),
            valueKey: 'negativeEquityFinanced',
            emphasis: true,
            color: theme.colorScheme.error,
          ),
        _Row(
          'Total cost over the term',
          money(o['totalCost']),
          valueKey: 'totalCost',
          emphasis: h.contains('totalCost'),
        ),
      ],
    );
  }
}

class _PaymentBreakdownCard extends StatelessWidget {
  const _PaymentBreakdownCard({required this.shown});
  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final h = shown.request.highlights.toSet();
    Widget section(String t) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(t, style: theme.textTheme.labelLarge),
    );
    return _CardShell(
      id: 'payment_breakdown',
      title: shown.request.title ?? 'Purchase breakdown',
      assumptions: assumptionsOf(shown.result),
      children: [
        section('What you pay'),
        _Row('Vehicle price', money(i['price'])),
        _Row('Sales tax', money(o['salesTax']), valueKey: 'salesTax'),
        _Row('Fees', money(i['fees'])),
        _Row('Down payment', '- ${money(i['downPayment'])}'),
        if ((o['tradeEquityApplied'] as num? ?? 0) > 0)
          _Row(
            'Trade-in equity applied',
            '- ${money(o['tradeEquityApplied'])}',
            valueKey: 'tradeEquityApplied',
          ),
        if ((o['negativeEquityFinanced'] as num? ?? 0) > 0)
          _Row(
            'Negative equity rolled in',
            '+ ${money(o['negativeEquityFinanced'])}',
            valueKey: 'negativeEquityFinanced',
            color: theme.colorScheme.error,
          ),
        _Row(
          'Amount financed',
          money(o['amountFinanced']),
          valueKey: 'amountFinanced',
          emphasis: true,
        ),
        section('The loan'),
        _Row('Term', '${i['termMonths']} months'),
        _Row('APR', percent(i['apr'])),
        _Row(
          'Monthly payment',
          money(o['monthlyPayment']),
          valueKey: 'monthlyPayment',
          emphasis: h.isEmpty || h.contains('monthlyPayment'),
        ),
        _Row('Total of payments', money(o['totalOfPayments']), valueKey: 'totalOfPayments'),
        _Row(
          'Finance charge (interest)',
          money(o['financeCharge']),
          valueKey: 'financeCharge',
          emphasis: h.contains('financeCharge'),
        ),
        section('All in'),
        _Row('Cash due at signing', money(o['cashDueAtSigning']), valueKey: 'cashDueAtSigning'),
        _Row(
          'Total cost over the term',
          money(o['totalCost']),
          valueKey: 'totalCost',
          emphasis: true,
        ),
      ],
    );
  }
}

class _TradeEquityCard extends StatelessWidget {
  const _TradeEquityCard({required this.shown});
  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final negative = o['isNegative'] == true;
    return _CardShell(
      id: 'trade_equity_card',
      title: shown.request.title ?? 'Your trade-in',
      assumptions: assumptionsOf(shown.result),
      children: [
        _Row('Estimated value', money(i['estimatedValue'])),
        _Row('Still owed', money(i['payoff'])),
        _Row(
          negative
              ? 'Negative equity (you owe more than it\'s worth)'
              : 'Equity toward the next vehicle',
          money(negative ? o['shortfall'] : o['equity']),
          valueKey: 'equity',
          emphasis: true,
          color: negative ? theme.colorScheme.error : null,
        ),
        if (negative)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'This amount either gets added to the next loan or paid in cash at signing. Both are shown in the payment breakdown.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _OutputsCard extends StatelessWidget {
  const _OutputsCard({required this.shown});
  final ShownComponent shown;

  static const _moneyKeys = {
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
    'monthlyPayment',
    'totalOfPayments',
  };

  @override
  Widget build(BuildContext context) {
    final o = outputsOf(shown.result);
    final h = shown.request.highlights.toSet();
    return _CardShell(
      id: shown.request.component.id,
      title: shown.request.title ?? labelFor(shown.request.component.id),
      assumptions: assumptionsOf(shown.result),
      children: [
        for (final e in o.entries)
          if (e.value is num || e.value is String || e.value is bool)
            _Row(
              labelFor(e.key),
              _moneyKeys.contains(e.key) ? money(e.value) : e.value.toString(),
              valueKey: e.key,
              emphasis: h.contains(e.key),
            ),
        if (o['warnings'] is List)
          for (final w in (o['warnings'] as List).cast<Map>())
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• ${w['message']}', style: Theme.of(context).textTheme.bodySmall),
            ),
      ],
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.shown, required this.onChoice});
  final ShownComponent shown;
  final void Function(String id, String label) onChoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = shown.request;
    final options = (req.props['options'] as List?)?.cast<Map>() ?? const [];
    if (shown.answered) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '${req.props['question'] ?? ''}',
          style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    }
    return Card(
      key: const Key('card-choice'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${req.props['question'] ?? req.title ?? ''}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in options)
                  ActionChip(
                    key: Key('choice-${o['id']}'),
                    label: Text('${o['label']}'),
                    onPressed: () => onChoice('${o['id']}', '${o['label']}'),
                  ),
                ActionChip(
                  key: const Key('choice-escape'),
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Something else'),
                  onPressed: () => onChoice('escape', 'Something else; let me explain.'),
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
  const _FormCard({required this.shown, required this.onSubmit});
  final ShownComponent shown;
  final void Function(String text) onSubmit;

  @override
  State<_FormCard> createState() => _FormCardState();
}

class _FormCardState extends State<_FormCard> {
  final Map<String, TextEditingController> _controllers = {};

  List<Map> get _fields => (widget.shown.request.props['fields'] as List?)?.cast<Map>() ?? const [];

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
    final title =
        '${widget.shown.request.props['title'] ?? widget.shown.request.title ?? 'A few details'}';
    if (widget.shown.answered) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(title, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
      );
    }
    return Card(
      key: const Key('card-input_form'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
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

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({required this.shown});
  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = shown.result?.result ?? const {};
    final listings = (r['listings'] as List?)?.cast<Map>() ?? const [];
    final source = r['source']?.toString();
    return Card(
      key: const Key('card-vehicle_card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shown.request.title ?? (listings.isEmpty ? 'No listings yet' : 'Listings'),
              style: theme.textTheme.titleMedium,
            ),
            if (source != null)
              Text(
                source,
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 6),
            if (listings.isEmpty)
              Text(
                '${r['note'] ?? 'Open a listings page and the advisor can read it.'}',
                style: theme.textTheme.bodySmall,
              ),
            for (final l in listings)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.directions_car_outlined),
                title: Text('${l['title']}'),
                subtitle: Text(
                  [
                    if (l['price'] != null) money(l['price'], cents: false),
                    if (l['mileage'] != null) '${_thousands(l['mileage'])} mi',
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _thousands(Object? v) => v is num
    ? v.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')
    : '';

class _PageExtractCard extends StatelessWidget {
  const _PageExtractCard({required this.shown});
  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = shown.result?.result ?? const {};
    final facts = (r['facts'] as Map?)?.cast<String, Object?>() ?? const {};
    final listings = (r['listings'] as List?)?.cast<Map>() ?? const [];
    final text = r['text']?.toString() ?? '';
    return Card(
      key: const Key('card-page_extract'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${r['title'] ?? 'Page'}',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${r['url'] ?? ''}',
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            if (facts.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (facts['prices'] is List)
                    for (final p in (facts['prices'] as List).take(3))
                      Chip(
                        label: Text(money(p, cents: false)),
                        visualDensity: VisualDensity.compact,
                      ),
                  if (facts['mileage'] != null)
                    Chip(
                      label: Text('${_thousands(facts['mileage'])} mi'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (facts['year'] != null)
                    Chip(label: Text('${facts['year']}'), visualDensity: VisualDensity.compact),
                ],
              ),
            if (listings.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('${listings.length} listings read', style: theme.textTheme.labelLarge),
              for (final l in listings.take(5))
                Text(
                  '• ${l['title']}${l['price'] != null ? ' · ${money(l['price'], cents: false)}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
            ] else if (text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                text.length > 400 ? '${text.substring(0, 400)}…' : text,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
