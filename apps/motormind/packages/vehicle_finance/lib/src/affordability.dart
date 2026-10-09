import 'assumption.dart';
import 'loan.dart';
import 'money.dart';

/// Thresholds used to *warn*, never to block. Defaults are common
/// rules of thumb, not lender policy.
class AffordabilityPolicy {
  /// Creates a policy; the defaults are 15% payment-to-income, 43%
  /// debt-to-income and a 72-month term.
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

  /// Longest loan term in months before a warning is raised.
  final int maxTermMonths;

  /// Where the thresholds came from; surfaced on the policy assumption.
  final String source;

  /// ISO-8601 date the thresholds were last reviewed.
  final String asOf;
}

/// The buyer's budget figures alongside the payment under consideration.
///
/// All money values are dollars per month.
class AffordabilityInputs {
  /// Creates the inputs; existing debt defaults to zero and the ceiling is
  /// optional.
  const AffordabilityInputs({
    required this.monthlyGrossIncome,
    required this.proposedPayment,
    required this.termMonths,
    this.monthlyDebtPayments = 0,
    this.paymentCeiling,
  });

  /// Gross (pre-tax) household income per month; must be positive.
  final double monthlyGrossIncome;

  /// The vehicle payment being evaluated.
  final double proposedPayment;

  /// Term of the proposed loan in months, checked against
  /// [AffordabilityPolicy.maxTermMonths].
  final int termMonths;

  /// Rent or mortgage, cards, student loans, other vehicles.
  final double monthlyDebtPayments;

  /// What the user said they can pay, if they said.
  final double? paymentCeiling;

  /// Serializes the inputs for the result's input record.
  Map<String, Object?> toJson() => {
    'monthlyGrossIncome': monthlyGrossIncome,
    'proposedPayment': proposedPayment,
    'termMonths': termMonths,
    'monthlyDebtPayments': monthlyDebtPayments,
    'paymentCeiling': paymentCeiling,
  };
}

/// One guideline the proposed payment exceeds.
///
/// Warnings inform; nothing in this package blocks a deal.
class AffordabilityWarning {
  /// Creates a warning from its machine code and user-facing message.
  const AffordabilityWarning({required this.code, required this.message});

  /// Stable machine code the UI and tests key on, e.g. `payment_to_income`.
  final String code;

  /// Plain-language explanation with the actual and guideline figures filled in.
  final String message;

  /// Serializes the warning for tool results.
  Map<String, Object?> toJson() => {'code': code, 'message': message};
}

/// How a proposed payment compares with the policy ratios, plus the largest
/// payment those ratios would allow.
class AffordabilityResult extends CalcResult {
  /// Creates a result from already-computed figures; [assessAffordability] is
  /// the usual way to get one. The [input] is serialized into [inputs].
  AffordabilityResult({
    required AffordabilityInputs input,
    required this.paymentToIncome,
    required this.debtToIncomeAfter,
    required this.suggestedMaxPayment,
    required this.warnings,
    required super.assumptions,
  }) : super(inputs: input.toJson());

  /// Proposed payment divided by gross monthly income, as a fraction rounded
  /// to four decimals.
  final double paymentToIncome;

  /// All monthly debt including the proposed payment, divided by gross monthly
  /// income, as a fraction rounded to four decimals.
  final double debtToIncomeAfter;

  /// The lower of the policy-derived ceiling and the user's own ceiling.
  final double suggestedMaxPayment;

  /// Every guideline exceeded, in policy order; empty when [withinGuidelines].
  final List<AffordabilityWarning> warnings;

  /// True when no guideline was exceeded.
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

/// Compares [input] against [policy] and reports the ratios, the suggested
/// maximum payment and one warning per guideline exceeded.
///
/// The suggested maximum is the smallest of the payment-to-income ceiling, the
/// debt-to-income ceiling after existing debt, and the user's own ceiling,
/// floored at zero. Throws an [ArgumentError] when income is not positive.
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
  var suggested = [
    policyCeiling,
    dtiCeiling,
    if (input.paymentCeiling != null) input.paymentCeiling!,
  ].reduce((a, b) => a < b ? a : b);
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
double maxPriceForPayment({
  required double payment,
  required double apr,
  required int termMonths,
}) => maxPrincipal(payment: payment, apr: apr, termMonths: termMonths);
