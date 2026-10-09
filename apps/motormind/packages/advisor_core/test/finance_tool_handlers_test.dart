import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  late FinanceToolHandlers handlers;
  final fixedNow = DateTime(2026, 3, 7);

  setUp(() => handlers = FinanceToolHandlers(now: () => fixedNow));

  test('every finance tool in the spec list is handled, and nothing else claims to be', () {
    const financeTools = {
      AdvisorTools.estimatePayment,
      AdvisorTools.maxAffordablePrice,
      AdvisorTools.tradeEquity,
      AdvisorTools.estimateLease,
      AdvisorTools.assessAffordability,
      AdvisorTools.ownershipCost,
    };
    for (final spec in AdvisorTools.all) {
      expect(handlers.handles(spec.name), financeTools.contains(spec.name), reason: spec.name);
    }
    expect(handlers.handles('present'), isFalse);
  });

  test('ids count per instance from r1 and are shared through nextId', () {
    final a = FinanceToolHandlers();
    final b = FinanceToolHandlers();
    expect(a.call(AdvisorTools.tradeEquity, {'estimated_value': 1, 'payoff': 1}).id, 'r1');
    expect(a.nextId(), 'r2');
    expect(a.call(AdvisorTools.tradeEquity, {'estimated_value': 1, 'payoff': 1}).id, 'r3');
    expect(b.call(AdvisorTools.tradeEquity, {'estimated_value': 1, 'payoff': 1}).id, 'r1');
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

  test('an exact APR overrides the band and is attributed to the user, dated by the clock', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'price': 10000,
      'term_months': 36,
      'credit_band': 'poor',
      'apr': 0.049,
    });
    final assumptions = (r.result!['assumptions'] as List).cast<Map>();
    expect(assumptions.first['key'], 'apr.user');
    expect(assumptions.first['illustrative'], isFalse);
    expect(assumptions.first['asOf'], '2026-03-07');
  });

  test('an APR written as "6%" is read as the rate 0.06, not 6', () {
    final r = handlers.call(AdvisorTools.estimatePayment, {
      'price': 10000,
      'term_months': 36,
      'credit_band': 'good',
      'apr': '6%',
    });
    expect(r.isError, isFalse, reason: r.error);
    expect((r.result!['inputs'] as Map)['apr'], 0.06);
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
    expect(r2.error, contains('credit_band'));
  });

  test('a wrongly typed enum argument is an error result, not a TypeError', () {
    final r = handlers.call(AdvisorTools.ownershipCost, {
      'vehicle_class': 'suv',
      'purchase_price': 28000,
      'miles_per_year': 12000,
      'fuel_type': 'gasoline',
      'efficiency': 25,
      'insurance_band': 2,
    });
    expect(r.isError, isTrue);
    expect(r.error, contains('insurance_band'));
    final r2 = handlers.call(AdvisorTools.ownershipCost, {
      'vehicle_class': 'SUV',
      'purchase_price': 28000,
      'miles_per_year': 12000,
      'fuel_type': 'Gasoline',
      'efficiency': 25,
      'insurance_band': 'Low',
    });
    expect(r2.isError, isFalse, reason: r2.error);
  });

  test('toModelJson of an error result carries the id and the error only', () {
    final r = handlers.call(AdvisorTools.tradeEquity, {'estimated_value': 'lots'});
    expect(r.isError, isTrue);
    expect(r.toModelJson(), {'result_id': 'r1', 'error': r.error});
  });

  test('toModelJson compacts whole-dollar doubles to ints and drops assumption prose', () {
    final r = handlers.call(AdvisorTools.tradeEquity, {'estimated_value': 6200, 'payoff': 8000});
    final json = r.toModelJson();
    expect((json['outputs'] as Map)['equity'], -1800);
    expect((json['outputs'] as Map)['equity'], isA<int>());
    expect((json['assumptions'] as List).first, startsWith('trade.value='));
  });

  group('each finance tool answers a well-formed call', () {
    test('max_affordable_price', () {
      final r = handlers.call(AdvisorTools.maxAffordablePrice, {
        'payment_ceiling': 450,
        'term_months': 60,
        'credit_band': 'good',
      });
      expect(r.isError, isFalse, reason: r.error);
      expect((r.result!['outputs'] as Map)['max_amount_financed'], greaterThan(0));
    });

    test('trade_equity', () {
      final r = handlers.call(AdvisorTools.tradeEquity, {'estimated_value': 6200, 'payoff': 8000});
      expect(r.result!['outputs'], containsPair('equity', -1800));
    });

    test('estimate_lease', () {
      final r = handlers.call(AdvisorTools.estimateLease, {
        'capitalized_cost': 30000,
        'residual_value': 18000,
        'money_factor': 0.00125,
        'term_months': 36,
      });
      expect(r.result!['outputs'], containsPair('monthlyPayment', 393.33));
    });

    test('assess_affordability', () {
      final r = handlers.call(AdvisorTools.assessAffordability, {
        'monthly_gross_income': 5000,
        'proposed_payment': 900,
        'term_months': 84,
      });
      expect(r.result!['outputs'], containsPair('withinGuidelines', false));
    });

    test('ownership_cost', () {
      final r = handlers.call(AdvisorTools.ownershipCost, {
        'vehicle_class': 'suv',
        'purchase_price': 28000,
        'miles_per_year': 12000,
        'fuel_type': 'gasoline',
        'efficiency': 25,
      });
      expect(r.isError, isFalse, reason: r.error);
    });
  });
}
