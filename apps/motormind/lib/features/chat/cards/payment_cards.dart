import 'package:flutter/material.dart';

import '../chat_state.dart';
import 'card_shell.dart';
import 'formatting.dart';

/// The headline payment from `estimate_payment`: the monthly figure large,
/// the amounts that produced it below. Negative equity rolled into the loan
/// is shown in the error color because it is the number people miss.
class PaymentSummaryCard extends StatelessWidget {
  const PaymentSummaryCard({super.key, required this.shown});

  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final highlights = shown.request.highlights.toSet();
    return CardShell(
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
        ValueRow(
          'Amount financed',
          money(o['amountFinanced']),
          valueKey: 'amountFinanced',
          emphasis: highlights.contains('amountFinanced'),
        ),
        ValueRow(
          'Cash due at signing',
          money(o['cashDueAtSigning']),
          valueKey: 'cashDueAtSigning',
          emphasis: highlights.contains('cashDueAtSigning'),
        ),
        if ((o['negativeEquityFinanced'] as num? ?? 0) > 0)
          ValueRow(
            'Negative equity rolled in',
            money(o['negativeEquityFinanced']),
            valueKey: 'negativeEquityFinanced',
            emphasis: true,
            color: theme.colorScheme.error,
          ),
        ValueRow(
          'Total cost over the term',
          money(o['totalCost']),
          valueKey: 'totalCost',
          emphasis: highlights.contains('totalCost'),
        ),
      ],
    );
  }
}

/// The full purchase arithmetic from `estimate_payment`, in the order a
/// buyer's order sheet shows it: what you pay, the loan, all in.
class PaymentBreakdownCard extends StatelessWidget {
  const PaymentBreakdownCard({super.key, required this.shown});

  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final highlights = shown.request.highlights.toSet();
    return CardShell(
      id: 'payment_breakdown',
      title: shown.request.title ?? 'Purchase breakdown',
      assumptions: assumptionsOf(shown.result),
      children: [
        const SectionLabel('What you pay'),
        ValueRow('Vehicle price', money(i['price'])),
        ValueRow('Sales tax', money(o['salesTax']), valueKey: 'salesTax'),
        ValueRow('Fees', money(i['fees'])),
        ValueRow('Down payment', '- ${money(i['downPayment'])}'),
        if ((o['tradeEquityApplied'] as num? ?? 0) > 0)
          ValueRow(
            'Trade-in equity applied',
            '- ${money(o['tradeEquityApplied'])}',
            valueKey: 'tradeEquityApplied',
          ),
        if ((o['negativeEquityFinanced'] as num? ?? 0) > 0)
          ValueRow(
            'Negative equity rolled in',
            '+ ${money(o['negativeEquityFinanced'])}',
            valueKey: 'negativeEquityFinanced',
            color: theme.colorScheme.error,
          ),
        ValueRow(
          'Amount financed',
          money(o['amountFinanced']),
          valueKey: 'amountFinanced',
          emphasis: true,
        ),
        const SectionLabel('The loan'),
        ValueRow('Term', '${i['termMonths']} months'),
        ValueRow('APR', percent(i['apr'])),
        ValueRow(
          'Monthly payment',
          money(o['monthlyPayment']),
          valueKey: 'monthlyPayment',
          emphasis: highlights.isEmpty || highlights.contains('monthlyPayment'),
        ),
        ValueRow('Total of payments', money(o['totalOfPayments']), valueKey: 'totalOfPayments'),
        ValueRow(
          'Finance charge (interest)',
          money(o['financeCharge']),
          valueKey: 'financeCharge',
          emphasis: highlights.contains('financeCharge'),
        ),
        const SectionLabel('All in'),
        ValueRow('Cash due at signing', money(o['cashDueAtSigning']), valueKey: 'cashDueAtSigning'),
        ValueRow(
          'Total cost over the term',
          money(o['totalCost']),
          valueKey: 'totalCost',
          emphasis: true,
        ),
      ],
    );
  }
}

/// The trade-in from `trade_equity`: value, payoff, and the equity or the
/// shortfall. A shortfall is the owner's differentiator (he ran a mortgage
/// company): it is named plainly and shown in the error color.
class TradeEquityCard extends StatelessWidget {
  const TradeEquityCard({super.key, required this.shown});

  final ShownComponent shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outputsOf(shown.result);
    final i = inputsOf(shown.result);
    final negative = o['isNegative'] == true;
    return CardShell(
      id: 'trade_equity_card',
      title: shown.request.title ?? 'Your trade-in',
      assumptions: assumptionsOf(shown.result),
      children: [
        ValueRow('Estimated value', money(i['estimatedValue'])),
        ValueRow('Still owed', money(i['payoff'])),
        ValueRow(
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
              'This amount either gets added to the next loan or paid in cash at signing. '
              'Both are shown in the payment breakdown.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// The generic card for any finance result without a hand-built layout
/// (affordability, lease, ownership cost): every scalar output as a row,
/// money-shaped keys formatted as money, warnings underneath.
class OutputsCard extends StatelessWidget {
  const OutputsCard({super.key, required this.shown});

  final ShownComponent shown;

  /// Output keys that hold dollar amounts. Everything else prints as is.
  static const _moneyKeys = {
    'suggestedMaxPayment',
    'maxAmountFinanced',
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
    final highlights = shown.request.highlights.toSet();
    final warnings = (o['warnings'] as List?)?.cast<Map>() ?? const [];
    return CardShell(
      id: shown.request.component.id,
      title: shown.request.title ?? labelFor(shown.request.component.id),
      assumptions: assumptionsOf(shown.result),
      children: [
        for (final e in o.entries)
          if (e.value is num || e.value is String || e.value is bool)
            ValueRow(
              labelFor(e.key),
              _moneyKeys.contains(e.key) ? money(e.value) : e.value.toString(),
              valueKey: e.key,
              emphasis: highlights.contains(e.key),
            ),
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('• ${w['message']}', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
