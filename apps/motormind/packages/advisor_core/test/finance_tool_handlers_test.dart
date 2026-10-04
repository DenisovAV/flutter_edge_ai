import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  var n = 0;
  final handlers = FinanceToolHandlers(nextId: () => 'r${++n}');

  setUp(() => n = 0);

  test('every finance tool in the spec list is handled, and nothing else claims to be', () {
    for (final spec in AdvisorTools.all) {
      expect(handlers.handles(spec.name), FinanceToolHandlers.handled.contains(spec.name));
    }
    expect(handlers.handles('present'), isFalse);
  });

  test('estimate_payment uses the band rate and produces the guard-verifiable shape', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'price': 20000,
      'term_months': 60,
      'credit_band': 'good',
      'down_payment': 1000,
      'sales_tax_rate': 0.07,
      'fees': 500,
      'trade_value': 6200,
      'trade_payoff': 8000,
    });
    expect(r.isError, isFalse, reason: r.error);
    expect(r.id, 'r1');
    final outputs = r.result!['outputs'] as Map<String, Object?>;
    expect(outputs['amountFinanced'], 22700);
    expect(outputs['negativeEquityFinanced'], 1800);
    final expected = monthlyPayment(
      principal: 22700,
      apr: defaultAprTable.aprFor(CreditBand.good, isNew: false),
      termMonths: 60,
    );
    expect(outputs['monthlyPayment'], expected);
    final assumptions = r.result!['assumptions'] as List;
    expect(assumptions.any((a) => (a as Map)['key'] == 'apr.used.good'), isTrue);
    expect(r.toModelJson()['result_id'], 'r1');
  });

  test('accepts numbers as strings with currency formatting', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'price': r'$18,500',
      'term_months': '48',
      'credit_band': 'fair',
    });
    expect(r.isError, isFalse, reason: r.error);
    expect((r.result!['inputs'] as Map)['price'], 18500);
  });

  test('an exact APR overrides the band and is attributed to the user', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'price': 10000,
      'term_months': 36,
      'credit_band': 'poor',
      'apr': 0.049,
    });
    final assumptions = (r.result!['assumptions'] as List).cast<Map>();
    expect(assumptions.first['key'], 'apr.user');
    expect(assumptions.first['illustrative'], isFalse);
  });

  test('bad arguments return an error the model can act on, never throw', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'term_months': 60,
      'credit_band': 'good',
    });
    expect(r.isError, isTrue);
    expect(r.error, contains('price'));
    final r2 = handlers.call(AdvisorTools.estimatePayment, {
      'price': 1,
      'term_months': 60,
      'credit_band': 'platinum',
    });
    expect(r2.isError, isTrue);
  });

  test('max_affordable_price, trade_equity, lease, affordability and ownership all answer', () {
    expect(
      handlers.call(AdvisorTools.maxAffordablePrice, {
        'payment_ceiling': 450,
        'term_months': 60,
        'credit_band': 'good',
      }).isError,
      isFalse,
    );
    expect(
      handlers.call(AdvisorTools.tradeEquity, {
        'estimated_value': 6200,
        'payoff': 8000,
      }).result!['outputs'],
      containsPair('equity', -1800),
    );
    expect(
      handlers.call(AdvisorTools.estimateLease, {
        'capitalized_cost': 30000,
        'residual_value': 18000,
        'money_factor': 0.00125,
        'term_months': 36,
      }).result!['outputs'],
      containsPair('monthlyPayment', 393.33),
    );
    expect(
      handlers.call(AdvisorTools.assessAffordability, {
        'monthly_gross_income': 5000,
        'proposed_payment': 900,
        'term_months': 84,
      }).result!['outputs'],
      containsPair('withinGuidelines', false),
    );
    expect(
      handlers.call(AdvisorTools.ownershipCost, {
        'vehicle_class': 'suv',
        'purchase_price': 28000,
        'miles_per_year': 12000,
        'fuel_type': 'gasoline',
        'efficiency': 25,
      }).isError,
      isFalse,
    );
  });
}
