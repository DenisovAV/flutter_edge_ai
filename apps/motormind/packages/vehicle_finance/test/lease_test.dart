import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

import 'fixtures.dart';

void main() {
  group('estimateLease', () {
    test('worked example: 30,000 cap, 18,000 residual, MF 0.00125, 36 months', () {
      const lease = LeaseInputs(
        capitalizedCost: 30000,
        residualValue: 18000,
        moneyFactor: 0.00125,
        termMonths: 36,
      );
      final e = estimateLease(lease, moneyFactorAssumption: moneyFactorAssumption);
      expect(e.depreciationCharge, 333.33);
      expect(e.rentCharge, 60.00);
      expect(e.basePayment, 393.33);
      expect(e.monthlyPayment, 393.33);
      expect(e.aprEquivalent, closeTo(0.03, 1e-9));
    });

    test('cap reduction and monthly tax', () {
      const lease = LeaseInputs(
        capitalizedCost: 30000,
        residualValue: 18000,
        moneyFactor: 0.00125,
        termMonths: 36,
        capReduction: 3000,
        salesTaxRate: 0.07,
      );
      final e = estimateLease(lease, moneyFactorAssumption: moneyFactorAssumption);
      expect(e.adjustedCapCost, 27000);
      expect(e.depreciationCharge, 250.00);
      expect(e.rentCharge, 56.25);
      expect(e.monthlyTax, closeTo(21.44, 0.01));
      expect(e.monthlyPayment, closeTo(327.69, 0.01));
    });

    test('carries the money factor and residual assumptions in that order', () {
      const lease = LeaseInputs(
        capitalizedCost: 30000,
        residualValue: 18000,
        moneyFactor: 0.00125,
        termMonths: 36,
      );
      final e = estimateLease(lease, moneyFactorAssumption: moneyFactorAssumption);
      expect(e.assumptions.map((a) => a.key), ['lease.mf', 'lease.residual']);
      expect(e.assumptions.last.illustrative, isFalse);
      expect(e.assumptions.last.asOf, assumptionsReviewedOn);
    });

    test('rejects an APR passed as a money factor', () {
      const lease = LeaseInputs(
        capitalizedCost: 30000,
        residualValue: 18000,
        moneyFactor: 0.06,
        termMonths: 36,
      );
      expect(
        () => estimateLease(lease, moneyFactorAssumption: moneyFactorAssumption),
        throwsArgumentError,
      );
    });

    test('money factor conversions round-trip', () {
      expect(moneyFactorToApr(0.0025), closeTo(0.06, 1e-12));
      expect(aprToMoneyFactor(0.06), closeTo(0.0025, 1e-12));
    });
  });
}
