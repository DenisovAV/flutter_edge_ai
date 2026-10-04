import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

const apr = Assumption(
  key: 'apr.test',
  description: 'test',
  value: '6%',
  source: 'test',
  asOf: '2026-10-04',
);

void main() {
  group('monthlyPayment', () {
    test('matches a textbook example: 25,000 at 6% for 60 months is 483.32', () {
      expect(monthlyPayment(principal: 25000, apr: 0.06, termMonths: 60), 483.32);
    });

    test('zero APR is straight division', () {
      expect(monthlyPayment(principal: 12000, apr: 0, termMonths: 24), 500.00);
    });

    test('zero principal is zero', () {
      expect(monthlyPayment(principal: 0, apr: 0.07, termMonths: 36), 0);
    });

    test('rejects a percentage passed as a whole number', () {
      expect(() => monthlyPayment(principal: 1, apr: 6, termMonths: 12), throwsArgumentError);
    });

    test('rejects a non-positive term', () {
      expect(() => monthlyPayment(principal: 1, apr: 0.06, termMonths: 0), throwsArgumentError);
    });
  });

  group('maxPrincipal', () {
    test('inverts monthlyPayment within a cent', () {
      final p = maxPrincipal(payment: 483.32, apr: 0.06, termMonths: 60);
      expect(p, closeTo(25000, 0.30));
      expect(monthlyPayment(principal: p, apr: 0.06, termMonths: 60), lessThanOrEqualTo(483.32));
    });

    test('zero APR', () {
      expect(maxPrincipal(payment: 500, apr: 0, termMonths: 24), 12000);
    });
  });

  group('amortizationSchedule', () {
    test('ends at zero balance and principal sums to the loan', () {
      final rows = amortizationSchedule(principal: 25000, apr: 0.06, termMonths: 60);
      expect(rows.length, 60);
      expect(rows.last.balance, 0);
      final principalSum = rows.fold<double>(0, (s, r) => s + r.principal);
      expect(principalSum, closeTo(25000, 0.01));
    });

    test('first period interest is principal times monthly rate', () {
      final rows = amortizationSchedule(principal: 25000, apr: 0.06, termMonths: 60);
      expect(rows.first.interest, 125.00);
      expect(rows.first.principal, closeTo(358.32, 0.01));
    });
  });

  group('summarizeLoan', () {
    test('finance charge is total paid minus principal', () {
      final s = summarizeLoan(principal: 25000, apr: 0.06, termMonths: 60, aprAssumption: apr);
      expect(s.monthlyPayment, 483.32);
      expect(s.totalOfPayments, closeTo(28999, 2));
      expect(s.financeCharge, closeTo(s.totalOfPayments - 25000, 0.01));
      expect(s.toJson()['inputs'], containsPair('principal', 25000));
      expect(s.assumptions, hasLength(1));
    });
  });
}
