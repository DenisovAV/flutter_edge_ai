import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

import 'fixtures.dart';

void main() {
  group('tradeEquity', () {
    test('negative equity is surfaced, not hidden', () {
      final t = tradeEquity(
        estimatedValue: 6200,
        payoff: 8000,
        valueAssumption: tradeValueAssumption,
      );
      expect(t.equity, -1800);
      expect(t.isNegative, isTrue);
      expect(t.shortfall, 1800);
      expect(t.outputsToJson()['isNegative'], isTrue);
    });

    test('positive equity has no shortfall', () {
      final t = tradeEquity(
        estimatedValue: 10000,
        payoff: 4000,
        valueAssumption: tradeValueAssumption,
      );
      expect(t.equity, 6000);
      expect(t.shortfall, 0);
    });
  });

  group('estimateDeal', () {
    test('rolls negative equity into the loan by default', () {
      final deal = DealInputs(
        price: 20000,
        apr: 0.06,
        termMonths: 60,
        salesTaxRate: 0.07,
        fees: 500,
        downPayment: 1000,
        trade: tradeEquity(
          estimatedValue: 6200,
          payoff: 8000,
          valueAssumption: tradeValueAssumption,
        ),
      );
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.salesTax, 1400);
      expect(e.negativeEquityFinanced, 1800);
      expect(e.tradeEquityApplied, 0);
      // 20000 + 1400 + 500 - 1000 + 1800
      expect(e.amountFinanced, 22700);
      expect(e.cashDueAtSigning, 1000);
      expect(e.cashBack, 0);
      expect(e.monthlyPayment, monthlyPayment(principal: 22700, apr: 0.06, termMonths: 60));
      expect(e.totalCost, closeTo(e.cashDueAtSigning + e.totalOfPayments, 0.01));
      expect(
        e.assumptions.map((a) => a.key),
        containsAll(['apr.test', 'tax.rate', 'fees.total', 'trade.value']),
      );
    });

    test('pays negative equity in cash when not rolled', () {
      final deal = DealInputs(
        price: 20000,
        apr: 0.06,
        termMonths: 60,
        downPayment: 1000,
        rollNegativeEquity: false,
        trade: tradeEquity(
          estimatedValue: 6200,
          payoff: 8000,
          valueAssumption: tradeValueAssumption,
        ),
      );
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.amountFinanced, 19000);
      expect(e.cashDueAtSigning, 2800);
      expect(e.negativeEquityFinanced, 0);
    });

    test('applies positive equity and the trade tax credit', () {
      final deal = DealInputs(
        price: 30000,
        apr: 0.05,
        termMonths: 48,
        salesTaxRate: 0.06,
        taxCreditForTrade: true,
        trade: tradeEquity(
          estimatedValue: 10000,
          payoff: 4000,
          valueAssumption: tradeValueAssumption,
        ),
      );
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.salesTax, 1200); // 6% of (30000 - 10000)
      expect(e.tradeEquityApplied, 6000);
      expect(e.amountFinanced, 25200);
    });

    test('never finances a negative amount', () {
      const deal = DealInputs(price: 5000, apr: 0.05, termMonths: 36, downPayment: 6000);
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.amountFinanced, 0);
      expect(e.monthlyPayment, 0);
      expect(e.cashDueAtSigning, 5000);
      expect(e.cashBack, 0);
    });

    test('equity beyond the deal is cash back, never negative cash at signing', () {
      final deal = DealInputs(
        price: 5000,
        apr: 0.05,
        termMonths: 36,
        trade: tradeEquity(estimatedValue: 10000, payoff: 0, valueAssumption: tradeValueAssumption),
      );
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.amountFinanced, 0);
      expect(e.cashDueAtSigning, 0);
      expect(e.cashBack, 5000);
      expect(e.tradeEquityApplied, 5000);
      expect(e.totalCost, 0);
    });

    test('surplus comes out of the down payment before it becomes cash back', () {
      final deal = DealInputs(
        price: 5000,
        apr: 0.05,
        termMonths: 36,
        downPayment: 1000,
        trade: tradeEquity(estimatedValue: 10000, payoff: 0, valueAssumption: tradeValueAssumption),
      );
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.amountFinanced, 0);
      expect(e.cashDueAtSigning, 0);
      expect(e.cashBack, 5000);
      expect(e.tradeEquityApplied, 5000);
    });

    test('carries the amortization schedule without serializing it', () {
      const deal = DealInputs(price: 25000, apr: 0.06, termMonths: 60);
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      expect(e.schedule, hasLength(60));
      expect(e.schedule.last.balance, 0);
      expect(e.schedule.fold<double>(0, (s, r) => s + r.payment), closeTo(e.totalOfPayments, 0.01));
      expect(e.outputsToJson(), isNot(contains('schedule')));
    });

    test('tax and fee assumptions carry the reviewed-on date', () {
      const deal = DealInputs(price: 25000, apr: 0.06, termMonths: 60, salesTaxRate: 0.07);
      final e = estimateDeal(deal, aprAssumption: aprAssumption);
      final dated = e.assumptions.where((a) => a.key == 'tax.rate' || a.key == 'fees.total');
      expect(dated.map((a) => a.asOf), everyElement(assumptionsReviewedOn));
    });
  });

  group('whatIfVariants', () {
    test(
      'produces three single-change alternatives with lower or equal payments where expected',
      () {
        const base = DealInputs(price: 25000, apr: 0.06, termMonths: 60, downPayment: 2000);
        final baseEstimate = estimateDeal(base, aprAssumption: aprAssumption);
        final v = whatIfVariants(base, aprAssumption: aprAssumption);
        expect(v, hasLength(3));
        expect(v[0].changed, {'termMonths': 48});
        expect(v[0].label, '48-month term');
        expect(v[0].estimate.monthlyPayment, greaterThan(baseEstimate.monthlyPayment));
        expect(v[0].estimate.financeCharge, lessThan(baseEstimate.financeCharge));
        expect(v[1].changed, {'downPayment': 3000});
        expect(v[1].label, r'$1000 more down');
        expect(v[1].estimate.monthlyPayment, lessThan(baseEstimate.monthlyPayment));
        expect(v[2].changed, {'price': 22500});
        expect(v[2].label, '10% lower price');
        expect(v[2].estimate.monthlyPayment, lessThan(baseEstimate.monthlyPayment));
      },
    );

    test('omits the shorter term when it would drop below 12 months', () {
      const base = DealInputs(price: 10000, apr: 0.06, termMonths: 12);
      final v = whatIfVariants(base, aprAssumption: aprAssumption);
      expect(v, hasLength(2));
      expect(v.map((x) => x.changed.keys.first), isNot(contains('termMonths')));
    });
  });
}
