import 'assumption.dart';
import 'money.dart';

/// Money factor to decimal APR. A money factor of 0.00250 is 6.0% APR.
double moneyFactorToApr(double moneyFactor) => moneyFactor * 24;

/// Decimal APR to money factor.
double aprToMoneyFactor(double apr) => apr / 24;

/// Terms of a closed-end lease as they appear on an offer sheet.
///
/// Money fields are in dollars. [moneyFactor] is the lessor's rent-charge
/// rate, not a percentage (0.0025 is roughly 6% APR); [salesTaxRate] is a
/// fraction.
class LeaseInputs {
  /// Creates the inputs; cap reduction and tax default to zero.
  const LeaseInputs({
    required this.capitalizedCost,
    required this.residualValue,
    required this.moneyFactor,
    required this.termMonths,
    this.capReduction = 0,
    this.salesTaxRate = 0,
  });

  /// Agreed price plus capitalized fees, before any cap reduction.
  final double capitalizedCost;

  /// What the lessor says the vehicle is worth at lease end, in dollars; set
  /// by the lessor and not negotiable.
  final double residualValue;

  /// Lessor's rent-charge rate; see [moneyFactorToApr] for the APR equivalent.
  final double moneyFactor;

  /// Length of the lease in months.
  final int termMonths;

  /// Down payment applied to the lease (cap cost reduction).
  final double capReduction;

  /// Monthly use tax applied to the payment; the common treatment in most
  /// states. States that tax the whole lease up front differ.
  final double salesTaxRate;

  /// Serializes the inputs for the result's input record.
  Map<String, Object?> toJson() => {
        'capitalizedCost': capitalizedCost,
        'residualValue': residualValue,
        'moneyFactor': moneyFactor,
        'termMonths': termMonths,
        'capReduction': capReduction,
        'salesTaxRate': salesTaxRate,
      };
}

/// A lease payment broken into the parts an offer sheet shows: depreciation,
/// rent charge and tax.
///
/// Every figure is monthly and in dollars except [totalOfPayments] (a total)
/// and [aprEquivalent] (a rate).
class LeaseEstimate extends CalcResult {
  /// Creates an estimate from already-computed figures; [estimateLease] is the
  /// usual way to get one. The [lease] inputs are serialized into [inputs].
  LeaseEstimate({
    required LeaseInputs lease,
    required this.adjustedCapCost,
    required this.depreciationCharge,
    required this.rentCharge,
    required this.basePayment,
    required this.monthlyTax,
    required this.monthlyPayment,
    required this.totalOfPayments,
    required this.aprEquivalent,
    required super.assumptions,
  }) : super(inputs: lease.toJson());

  /// Capitalized cost after cap reduction; the amount the lease finances.
  final double adjustedCapCost;

  /// Monthly share of the drop from [adjustedCapCost] to the residual:
  /// `(cap − residual) / term`.
  final double depreciationCharge;

  /// Monthly finance charge, `(cap + residual) × money factor`; the lease
  /// analogue of interest.
  final double rentCharge;

  /// [depreciationCharge] plus [rentCharge], before tax.
  final double basePayment;

  /// Use tax on [basePayment].
  final double monthlyTax;

  /// [basePayment] plus [monthlyTax]; what is due each month.
  final double monthlyPayment;

  /// [monthlyPayment] times the term; excludes the cap reduction and anything
  /// else due at signing.
  final double totalOfPayments;

  /// The money factor expressed as a nominal APR fraction, for comparison with
  /// a loan.
  final double aprEquivalent;

  @override
  Map<String, Object?> outputsToJson() => {
        'adjustedCapCost': adjustedCapCost,
        'depreciationCharge': depreciationCharge,
        'rentCharge': rentCharge,
        'basePayment': basePayment,
        'monthlyTax': monthlyTax,
        'monthlyPayment': monthlyPayment,
        'totalOfPayments': totalOfPayments,
        'aprEquivalent': aprEquivalent,
      };
}

/// Computes the standard closed-end lease payment: straight-line depreciation
/// to the residual plus a rent charge on the sum of cap cost and residual,
/// then tax on the total.
///
/// [moneyFactorAssumption] documents where the money factor came from; the
/// residual is recorded as a second, non-illustrative assumption.
///
/// Throws an [ArgumentError] for a non-positive term or a money factor outside
/// 0–0.05, which usually means an APR was passed by mistake.
LeaseEstimate estimateLease(LeaseInputs lease, {required Assumption moneyFactorAssumption}) {
  if (lease.termMonths <= 0) {
    throw ArgumentError.value(lease.termMonths, 'termMonths', 'must be positive');
  }
  if (lease.moneyFactor < 0 || lease.moneyFactor > 0.05) {
    throw ArgumentError.value(lease.moneyFactor, 'moneyFactor', 'expected a money factor like 0.0025');
  }
  final adjusted = lease.capitalizedCost - lease.capReduction;
  final depreciation = roundCents((adjusted - lease.residualValue) / lease.termMonths);
  final rent = roundCents((adjusted + lease.residualValue) * lease.moneyFactor);
  final base = roundCents(depreciation + rent);
  final tax = roundCents(base * lease.salesTaxRate);
  final payment = roundCents(base + tax);
  return LeaseEstimate(
    lease: lease,
    adjustedCapCost: roundCents(adjusted),
    depreciationCharge: depreciation,
    rentCharge: rent,
    basePayment: base,
    monthlyTax: tax,
    monthlyPayment: payment,
    totalOfPayments: roundCents(payment * lease.termMonths),
    aprEquivalent: moneyFactorToApr(lease.moneyFactor),
    assumptions: [
      moneyFactorAssumption,
      Assumption(
        key: 'lease.residual',
        description: 'Residual value set by the lessor; it is not negotiable and drives most of the payment.',
        value: lease.residualValue.toStringAsFixed(2),
        source: 'user or lease offer',
        asOf: '2026-10-04',
        illustrative: false,
      ),
    ],
  );
}
