import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

const apr = Assumption(
  key: 'apr.test',
  description: 'test',
  value: '6%',
  source: 'test',
  asOf: '2026-10-04',
);
const value = Assumption(
  key: 'trade.value',
  description: 'test',
  value: 'user',
  source: 'user',
  asOf: '2026-10-04',
);

void main() {
  group('tradeEquity', () {
    test('negative equity is surfaced, not hidden', () {
      final t = tradeEquity(estimatedValue: 6200, payoff: 8000, valueAssumption: value);
      expect(t.equity, -1800);
      expect(t.isNegative, isTrue);
      expect(t.shortfall, 1800);
      expect(t.outputsToJson()['isNegative'], isTrue);
    });

    test('positive equity has no shortfall', () {
      final t = tradeEquity(estimatedValue: 10000, payoff: 4000, valueAssumption: value);
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
        trade: tradeEquity(estimatedValue: 6200, payoff: 8000, valueAssumption: value),
      );
      final e = estimateDeal(deal, aprAssumption: apr);
      expect(e.salesTax, 1400);
      expect(e.negativeEquityFinanced, 1800);
      expect(e.tradeEquityApplied, 0);
      // 20000 + 1400 + 500 - 1000 + 1800
      expect(e.amountFinanced, 22700);
      expect(e.cashDueAtSigning, 1000);
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
        trade: tradeEquity(estimatedValue: 6200, payoff: 8000, valueAssumption: value),
      );
      final e = estimateDeal(deal, aprAssumption: apr);
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
        trade: tradeEquity(estimatedValue: 10000, payoff: 4000, valueAssumption: value),
      );
      final e = estimateDeal(deal, aprAssumption: apr);
      expect(e.salesTax, 1200); // 6% of (30000 - 10000)
      expect(e.tradeEquityApplied, 6000);
      expect(e.amountFinanced, 25200);
    });

    test('never finances a negative amount', () {
      final deal = DealInputs(price: 5000, apr: 0.05, termMonths: 36, downPayment: 6000);
      final e = estimateDeal(deal, aprAssumption: apr);
      expect(e.amountFinanced, 0);
      expect(e.monthlyPayment, 0);
      expect(e.cashDueAtSigning, 5000);
    });
  });

  group('whatIfVariants', () {
    test(
      'produces three single-change alternatives with lower or equal payments where expected',
      () {
        const base = DealInputs(price: 25000, apr: 0.06, termMonths: 60, downPayment: 2000);
        final baseEstimate = estimateDeal(base, aprAssumption: apr);
        final v = whatIfVariants(base, aprAssumption: apr);
        expect(v, hasLength(3));
        expect(v[0].changed, {'termMonths': 48});
        expect(v[0].estimate.monthlyPayment, greaterThan(baseEstimate.monthlyPayment));
        expect(v[0].estimate.financeCharge, lessThan(baseEstimate.financeCharge));
        expect(v[1].changed, {'downPayment': 3000});
        expect(v[1].estimate.monthlyPayment, lessThan(baseEstimate.monthlyPayment));
        expect(v[2].changed, {'price': 22500});
        expect(v[2].estimate.monthlyPayment, lessThan(baseEstimate.monthlyPayment));
      },
    );

    test('omits the shorter term when it would drop below 12 months', () {
      const base = DealInputs(price: 10000, apr: 0.06, termMonths: 12);
      final v = whatIfVariants(base, aprAssumption: apr);
      expect(v.map((x) => x.changed.keys.first), isNot(contains('termMonths')));
    });
  });
}
