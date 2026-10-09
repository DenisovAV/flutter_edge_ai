import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  group('assessAffordability', () {
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
      expect(r.debtToIncomeAfter, 0.325);
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

    test('ratios are rounded to four places', () {
      final r = assessAffordability(
        const AffordabilityInputs(monthlyGrossIncome: 3000, proposedPayment: 700, termMonths: 60),
      );
      expect(r.paymentToIncome, 0.2333);
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

    test('rejects zero income rather than dividing by it', () {
      expect(
        () => assessAffordability(
          const AffordabilityInputs(monthlyGrossIncome: 0, proposedPayment: 100, termMonths: 36),
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'monthlyGrossIncome')),
      );
    });

    test('policy assumption carries the reviewed-on date', () {
      final r = assessAffordability(
        const AffordabilityInputs(monthlyGrossIncome: 5000, proposedPayment: 300, termMonths: 48),
      );
      expect(r.assumptions.single.key, 'affordability.policy');
      expect(r.assumptions.single.asOf, assumptionsReviewedOn);
    });
  });
}
