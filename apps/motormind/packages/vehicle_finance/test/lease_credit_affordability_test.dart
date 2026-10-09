import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

const mf = Assumption(
  key: 'lease.mf',
  description: 'test',
  value: '0.00125',
  source: 'test',
  asOf: '2026-10-04',
);

void main() {
  group('lease', () {
    test('worked example: 30,000 cap, 18,000 residual, MF 0.00125, 36 months', () {
      const lease = LeaseInputs(
        capitalizedCost: 30000,
        residualValue: 18000,
        moneyFactor: 0.00125,
        termMonths: 36,
      );
      final e = estimateLease(lease, moneyFactorAssumption: mf);
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
      final e = estimateLease(lease, moneyFactorAssumption: mf);
      expect(e.adjustedCapCost, 27000);
      expect(e.depreciationCharge, 250.00);
      expect(e.rentCharge, 56.25);
      expect(e.monthlyTax, closeTo(21.44, 0.01));
      expect(e.monthlyPayment, closeTo(327.69, 0.01));
    });

    test('money factor conversions round-trip', () {
      expect(moneyFactorToApr(0.0025), closeTo(0.06, 1e-12));
      expect(aprToMoneyFactor(0.06), closeTo(0.0025, 1e-12));
    });
  });

  group('credit', () {
    test('score maps to band at the boundaries', () {
      expect(creditBandForScore(850), CreditBand.excellent);
      expect(creditBandForScore(781), CreditBand.excellent);
      expect(creditBandForScore(780), CreditBand.good);
      expect(creditBandForScore(661), CreditBand.good);
      expect(creditBandForScore(660), CreditBand.fair);
      expect(creditBandForScore(601), CreditBand.fair);
      expect(creditBandForScore(600), CreditBand.poor);
      expect(creditBandForScore(501), CreditBand.poor);
      expect(creditBandForScore(500), CreditBand.rebuilding);
      expect(creditBandForScore(0), CreditBand.rebuilding);
      expect(creditBandForScore(999), CreditBand.excellent);
    });

    test('default table is labeled illustrative, sourced, and round-trips through JSON', () {
      expect(defaultAprTable.illustrative, isTrue);
      expect(defaultAprTable.source, contains('Experian'));
      final json = defaultAprTable.toJson();
      final back = AprTable.fromJson(json);
      expect(back.aprFor(CreditBand.fair, isNew: false), 0.1393);
      final a = back.assumptionFor(CreditBand.good, isNew: true);
      expect(a.key, 'apr.new.good');
      expect(a.value, '6.15%');
      expect(a.illustrative, isTrue);
    });

    test('used rates are never below new rates, and rates rise as credit falls', () {
      final bands = CreditBand.values;
      for (var i = 1; i < bands.length; i++) {
        expect(
          defaultAprTable.aprFor(bands[i], isNew: true),
          greaterThan(defaultAprTable.aprFor(bands[i - 1], isNew: true)),
        );
      }
      for (final r in defaultAprTable.rates.values) {
        expect(r.usedVehicle, greaterThanOrEqualTo(r.newVehicle));
      }
    });
  });

  group('affordability', () {
    test('within guidelines produces no warnings', () {
      final r = assessAffordability(
        const AffordabilityInputs(
          monthlyGrossIncome: 6000,
          proposedPayment: 450,
          termMonths: 60,
          monthlyDebtPayments: 1500,
        ),
      );
      expect(r.withinGuidelines, isTrue);
      expect(r.paymentToIncome, 0.075);
      expect(r.suggestedMaxPayment, 900); // 15% of 6000
    });

    test('warns, never throws, on payment, DTI, term and ceiling', () {
      final r = assessAffordability(
        const AffordabilityInputs(
          monthlyGrossIncome: 3000,
          proposedPayment: 700,
          termMonths: 84,
          monthlyDebtPayments: 900,
          paymentCeiling: 450,
        ),
      );
      expect(
        r.warnings.map((w) => w.code),
        containsAll(['payment_to_income', 'debt_to_income', 'long_term', 'over_ceiling']),
      );
      // 43% of 3000 = 1290, minus 900 debt = 390; min with 450 ceiling and 450 (15%) is 390.
      expect(r.suggestedMaxPayment, 390);
    });

    test('suggested payment never goes negative', () {
      final r = assessAffordability(
        const AffordabilityInputs(
          monthlyGrossIncome: 2000,
          proposedPayment: 100,
          termMonths: 36,
          monthlyDebtPayments: 1900,
        ),
      );
      expect(r.suggestedMaxPayment, 0);
    });

    test('maxPriceForPayment delegates to maxPrincipal', () {
      expect(maxPriceForPayment(payment: 500, apr: 0, termMonths: 24), 12000);
    });
  });

  group('ownership', () {
    test('five-year estimate is the sum of its parts and carries assumptions', () {
      final e = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.suv,
          purchasePrice: 28000,
          milesPerYear: 12000,
          fuelType: FuelType.gasoline,
          efficiency: 25,
          salesTaxRate: 0.07,
        ),
      );
      expect(e.fuelOrEnergy, 8400); // 60000 miles / 25 mpg * 3.50
      expect(e.insurance, 9500);
      expect(e.depreciation, closeTo(28000 * 0.55, 0.01));
      expect(e.taxesAndFees, closeTo(28000 * 0.07 + 750, 0.01));
      expect(
        e.total,
        closeTo(
          e.depreciation + e.fuelOrEnergy + e.insurance + e.maintenance + e.taxesAndFees,
          0.01,
        ),
      );
      expect(e.assumptions.every((a) => a.illustrative), isTrue);
    });

    test('a used vehicle depreciates less in absolute terms than the same price new', () {
      const base = OwnershipInputs(
        vehicleClass: VehicleClass.car,
        purchasePrice: 20000,
        milesPerYear: 10000,
        fuelType: FuelType.hybrid,
        efficiency: 45,
      );
      final newer = estimateOwnership(base);
      final older = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.car,
          purchasePrice: 20000,
          milesPerYear: 10000,
          fuelType: FuelType.hybrid,
          efficiency: 45,
          vehicleAgeYears: 4,
        ),
      );
      expect(older.depreciation, lessThan(newer.depreciation));
      expect(older.maintenance, greaterThan(newer.maintenance));
    });

    test('electric uses miles per kWh and electricity price', () {
      final e = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.car,
          purchasePrice: 35000,
          milesPerYear: 10000,
          fuelType: FuelType.electric,
          efficiency: 4,
          years: 1,
          electricityPerKwh: 0.20,
        ),
      );
      expect(e.fuelOrEnergy, 500); // 10000 / 4 * 0.20
    });
  });
}
