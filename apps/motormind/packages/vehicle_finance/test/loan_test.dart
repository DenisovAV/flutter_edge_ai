import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

import 'fixtures.dart';

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

    test('names the principal in its negative-amount error', () {
      expect(
        () => monthlyPayment(principal: -1, apr: 0.06, termMonths: 12),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'principal')),
      );
    });
  });

  group('maxPrincipal', () {
    test('inverts a rounded payment to the cent below the original principal', () {
      final p = maxPrincipal(payment: 483.32, apr: 0.06, termMonths: 60);
      expect(p, 24999.99);
      expect(monthlyPayment(principal: p, apr: 0.06, termMonths: 60), lessThanOrEqualTo(483.32));
    });

    test('zero APR', () {
      expect(maxPrincipal(payment: 500, apr: 0, termMonths: 24), 12000);
    });

    test('names the payment in its negative-amount error', () {
      expect(
        () => maxPrincipal(payment: -1, apr: 0.06, termMonths: 12),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'payment')),
      );
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

    test('stops early when the rounded payment pays the loan off before the term ends', () {
      // 1.00 over 120 months rounds to a 0.01 payment, which clears the balance in 100.
      final rows = amortizationSchedule(principal: 1, apr: 0, termMonths: 120);
      expect(rows.length, 100);
      expect(rows.last.balance, 0);
      expect(rows.fold<double>(0, (s, r) => s + r.principal), closeTo(1, 0.001));
    });
  });

  group('summarizeLoan', () {
    test('finance charge is total paid minus principal', () {
      final s = summarizeLoan(
        principal: 25000,
        apr: 0.06,
        termMonths: 60,
        aprAssumption: aprAssumption,
      );
      expect(s.monthlyPayment, 483.32);
      expect(s.totalOfPayments, 28999.23);
      expect(s.financeCharge, 3999.23);
      expect(s.schedule, hasLength(60));
      expect(s.toJson()['inputs'], containsPair('principal', 25000));
      expect(s.assumptions, hasLength(1));
    });
  });
}
