import 'dart:math' as math;

import 'assumption.dart';
import 'money.dart';

/// Standard amortized monthly payment, rounded to the cent.
///
/// Uses the level-payment amortization formula `P·r·(1+r)^n / ((1+r)^n − 1)`
/// with `r` the nominal [apr] divided by 12 and `n` the term in months, which
/// assumes monthly compounding and no fees in the rate. [apr] is a fraction:
/// `0.065` for 6.5%. A zero APR is a straight division.
double monthlyPayment({
  required double principal,
  required double apr,
  required int termMonths,
}) {
  _checkLoanArgs(principal: principal, apr: apr, termMonths: termMonths);
  if (principal == 0) return 0;
  final r = apr / 12;
  if (r == 0) return roundCents(principal / termMonths);
  final growth = math.pow(1 + r, termMonths).toDouble();
  return roundCents(principal * r * growth / (growth - 1));
}

/// The largest principal a [payment] can carry at [apr] over [termMonths].
///
/// Inverse of [monthlyPayment]. Rounds down to the cent so the payment on the
/// returned principal never exceeds [payment].
double maxPrincipal({
  required double payment,
  required double apr,
  required int termMonths,
}) {
  _checkLoanArgs(principal: payment, apr: apr, termMonths: termMonths);
  if (payment == 0) return 0;
  final r = apr / 12;
  if (r == 0) return (payment * termMonths * 100).floor() / 100;
  final growth = math.pow(1 + r, termMonths).toDouble();
  return (payment * (growth - 1) / (r * growth) * 100).floor() / 100;
}

/// One period of an amortization schedule.
class AmortizationRow {
  /// Creates a row; every money value is in dollars, already rounded to the cent.
  const AmortizationRow({
    required this.period,
    required this.payment,
    required this.interest,
    required this.principal,
    required this.balance,
  });

  /// One-based month number within the term.
  final int period;

  /// Total paid this period, in dollars; the final row may differ from the
  /// regular payment because it absorbs rounding.
  final double payment;

  /// Share of [payment] that is interest on the opening balance, in dollars.
  final double interest;

  /// Share of [payment] that reduces the balance, in dollars.
  final double principal;

  /// Balance remaining after this payment, in dollars; zero on the final row.
  final double balance;

  /// Serializes the row for tool results and logs.
  Map<String, Object?> toJson() => {
        'period': period,
        'payment': payment,
        'interest': interest,
        'principal': principal,
        'balance': balance,
      };
}

/// Full amortization schedule. The final row absorbs rounding so the balance
/// ends at exactly zero and the sum of principal equals [principal].
List<AmortizationRow> amortizationSchedule({
  required double principal,
  required double apr,
  required int termMonths,
}) {
  _checkLoanArgs(principal: principal, apr: apr, termMonths: termMonths);
  final payment = monthlyPayment(principal: principal, apr: apr, termMonths: termMonths);
  final r = apr / 12;
  final rows = <AmortizationRow>[];
  var balance = principal;
  for (var period = 1; period <= termMonths; period++) {
    final interest = roundCents(balance * r);
    var principalPart = roundCents(payment - interest);
    var thisPayment = payment;
    if (period == termMonths || principalPart > balance) {
      principalPart = roundCents(balance);
      thisPayment = roundCents(principalPart + interest);
    }
    balance = roundCents(balance - principalPart);
    rows.add(AmortizationRow(
      period: period,
      payment: thisPayment,
      interest: interest,
      principal: principalPart,
      balance: balance < 0 ? 0 : balance,
    ));
    if (balance <= 0) break;
  }
  return rows;
}

/// Payment, total of payments and finance charge for a loan.
///
/// The inputs carry [principal], [apr] and [termMonths]; the outputs report
/// the money figures and the schedule length rather than every row.
class LoanSummary extends CalcResult {
  /// Creates a summary from already-computed figures; [summarizeLoan] is the
  /// usual way to get one.
  LoanSummary({
    required this.principal,
    required this.apr,
    required this.termMonths,
    required this.monthlyPayment,
    required this.totalOfPayments,
    required this.financeCharge,
    required this.schedule,
    required super.assumptions,
  }) : super(inputs: {
          'principal': principal,
          'apr': apr,
          'termMonths': termMonths,
        });

  /// Amount borrowed, in dollars.
  final double principal;

  /// Nominal APR as a fraction (0.065 for 6.5%), compounded monthly.
  final double apr;

  /// Length of the loan in months.
  final int termMonths;

  /// Regular monthly payment in dollars, from the amortization formula.
  final double monthlyPayment;

  /// Sum of every scheduled payment in dollars, including the adjusted final one.
  final double totalOfPayments;

  /// Interest paid over the life of the loan: [totalOfPayments] minus
  /// [principal], in dollars.
  final double financeCharge;

  /// Month-by-month breakdown, one row per payment.
  final List<AmortizationRow> schedule;

  @override
  Map<String, Object?> outputsToJson() => {
        'monthlyPayment': monthlyPayment,
        'totalOfPayments': totalOfPayments,
        'financeCharge': financeCharge,
        'scheduleLength': schedule.length,
      };
}

/// Builds a [LoanSummary] for [principal] at [apr] over [termMonths].
///
/// The total of payments is summed from the schedule rather than multiplied
/// from the payment, so it matches the rows to the cent. [aprAssumption]
/// documents where the APR came from.
LoanSummary summarizeLoan({
  required double principal,
  required double apr,
  required int termMonths,
  required Assumption aprAssumption,
}) {
  final schedule = amortizationSchedule(principal: principal, apr: apr, termMonths: termMonths);
  final total = roundCents(schedule.fold<double>(0, (sum, row) => sum + row.payment));
  return LoanSummary(
    principal: principal,
    apr: apr,
    termMonths: termMonths,
    monthlyPayment: monthlyPayment(principal: principal, apr: apr, termMonths: termMonths),
    totalOfPayments: total,
    financeCharge: roundCents(total - principal),
    schedule: schedule,
    assumptions: [aprAssumption],
  );
}

void _checkLoanArgs({required double principal, required double apr, required int termMonths}) {
  if (termMonths <= 0) {
    throw ArgumentError.value(termMonths, 'termMonths', 'must be positive');
  }
  if (principal < 0) {
    throw ArgumentError.value(principal, 'principal', 'must not be negative');
  }
  if (apr < 0 || apr > 1) {
    throw ArgumentError.value(apr, 'apr', 'must be a decimal between 0 and 1 (0.065 for 6.5%)');
  }
}
