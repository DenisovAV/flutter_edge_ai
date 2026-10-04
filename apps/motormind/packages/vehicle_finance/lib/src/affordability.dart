import 'assumption.dart';
import 'loan.dart';
import 'money.dart';

/// Thresholds used to *warn*, never to block. Defaults are common
/// rules of thumb, not lender policy.
class AffordabilityPolicy {
  const AffordabilityPolicy({
    this.maxPaymentToIncome = 0.15,
    this.maxDebtToIncome = 0.43,
    this.maxTermMonths = 72,
    this.source = 'rule of thumb; not a lender guideline',
    this.asOf = '2026-10-04',
  });

  /// Vehicle payment as a share of gross monthly income.
  final double maxPaymentToIncome;

  /// All monthly debt including the vehicle payment, as a share of gross
  /// monthly income.
  final double maxDebtToIncome;
  final int maxTermMonths;
  final String source;
  final String asOf;
}

class AffordabilityInputs {
  const AffordabilityInputs({
    required this.monthlyGrossIncome,
    required this.proposedPayment,
    required this.termMonths,
    this.monthlyDebtPayments = 0,
    this.paymentCeiling,
  });

  final double monthlyGrossIncome;
  final double proposedPayment;
  final int termMonths;

  /// Rent or mortgage, cards, student loans, other vehicles.
  final double monthlyDebtPayments;

  /// What the user said they can pay, if they said.
  final double? paymentCeiling;

  Map<String, Object?> toJson() => {
        'monthlyGrossIncome': monthlyGrossIncome,
        'proposedPayment': proposedPayment,
        'termMonths': termMonths,
        'monthlyDebtPayments': monthlyDebtPayments,
        'paymentCeiling': paymentCeiling,
      };
}

class AffordabilityWarning {
  const AffordabilityWarning({required this.code, required this.message});

  final String code;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'message': message};
}

class AffordabilityResult extends CalcResult {
  AffordabilityResult({
    required AffordabilityInputs input,
    required this.paymentToIncome,
    required this.debtToIncomeAfter,
    required this.suggestedMaxPayment,
    required this.warnings,
    required super.assumptions,
  }) : super(inputs: input.toJson());

  final double paymentToIncome;
  final double debtToIncomeAfter;

  /// The lower of the policy-derived ceiling and the user's own ceiling.
  final double suggestedMaxPayment;
  final List<AffordabilityWarning> warnings;

  bool get withinGuidelines => warnings.isEmpty;

  @override
  Map<String, Object?> outputsToJson() => {
        'paymentToIncome': paymentToIncome,
        'debtToIncomeAfter': debtToIncomeAfter,
        'suggestedMaxPayment': suggestedMaxPayment,
        'withinGuidelines': withinGuidelines,
        'warnings': [for (final w in warnings) w.toJson()],
      };
}

AffordabilityResult assessAffordability(
  AffordabilityInputs input, {
  AffordabilityPolicy policy = const AffordabilityPolicy(),
}) {
  if (input.monthlyGrossIncome <= 0) {
    throw ArgumentError.value(input.monthlyGrossIncome, 'monthlyGrossIncome', 'must be positive');
  }
  final income = input.monthlyGrossIncome;
  final pti = input.proposedPayment / income;
  final dti = (input.monthlyDebtPayments + input.proposedPayment) / income;

  final policyCeiling = roundCents(income * policy.maxPaymentToIncome);
  final dtiCeiling = roundCents(income * policy.maxDebtToIncome - input.monthlyDebtPayments);
  var suggested = [policyCeiling, dtiCeiling, if (input.paymentCeiling != null) input.paymentCeiling!]
      .reduce((a, b) => a < b ? a : b);
  if (suggested < 0) suggested = 0;

  final warnings = <AffordabilityWarning>[
    if (pti > policy.maxPaymentToIncome)
      AffordabilityWarning(
        code: 'payment_to_income',
        message:
            'This payment is ${(pti * 100).toStringAsFixed(0)}% of gross monthly income; a common guideline is ${(policy.maxPaymentToIncome * 100).toStringAsFixed(0)}% or less.',
      ),
    if (dti > policy.maxDebtToIncome)
      AffordabilityWarning(
        code: 'debt_to_income',
        message:
            'Total monthly debt would be ${(dti * 100).toStringAsFixed(0)}% of gross income; many lenders look for ${(policy.maxDebtToIncome * 100).toStringAsFixed(0)}% or less.',
      ),
    if (input.termMonths > policy.maxTermMonths)
      AffordabilityWarning(
        code: 'long_term',
        message:
            'A ${input.termMonths}-month term is longer than ${policy.maxTermMonths} months; longer terms lower the payment but raise total interest and the time spent underwater.',
      ),
    if (input.paymentCeiling != null && input.proposedPayment > input.paymentCeiling!)
      AffordabilityWarning(
        code: 'over_ceiling',
        message: 'This payment is above the ceiling you set.',
      ),
  ];

  return AffordabilityResult(
    input: input,
    paymentToIncome: double.parse(pti.toStringAsFixed(4)),
    debtToIncomeAfter: double.parse(dti.toStringAsFixed(4)),
    suggestedMaxPayment: suggested,
    warnings: warnings,
    assumptions: [
      Assumption(
        key: 'affordability.policy',
        description:
            'Guideline ratios: payment at most ${(policy.maxPaymentToIncome * 100).toStringAsFixed(0)}% of gross income, all debt at most ${(policy.maxDebtToIncome * 100).toStringAsFixed(0)}%, term at most ${policy.maxTermMonths} months.',
        value: '${policy.maxPaymentToIncome}/${policy.maxDebtToIncome}/${policy.maxTermMonths}',
        source: policy.source,
        asOf: policy.asOf,
      ),
    ],
  );
}

/// Convenience: the most expensive vehicle a payment ceiling supports at a
/// given APR and term, before tax, fees and trade.
double maxPriceForPayment({required double payment, required double apr, required int termMonths}) =>
    maxPrincipal(payment: payment, apr: apr, termMonths: termMonths);
