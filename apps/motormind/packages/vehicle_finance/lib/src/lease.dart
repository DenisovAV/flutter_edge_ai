import 'assumption.dart';
import 'money.dart';

/// Money factor to decimal APR. A money factor of 0.00250 is 6.0% APR.
double moneyFactorToApr(double moneyFactor) => moneyFactor * 24;

/// Decimal APR to money factor.
double aprToMoneyFactor(double apr) => apr / 24;

class LeaseInputs {
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
  final double residualValue;
  final double moneyFactor;
  final int termMonths;

  /// Down payment applied to the lease (cap cost reduction).
  final double capReduction;

  /// Monthly use tax applied to the payment; the common treatment in most
  /// states. States that tax the whole lease up front differ.
  final double salesTaxRate;

  Map<String, Object?> toJson() => {
        'capitalizedCost': capitalizedCost,
        'residualValue': residualValue,
        'moneyFactor': moneyFactor,
        'termMonths': termMonths,
        'capReduction': capReduction,
        'salesTaxRate': salesTaxRate,
      };
}

class LeaseEstimate extends CalcResult {
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

  final double adjustedCapCost;
  final double depreciationCharge;
  final double rentCharge;
  final double basePayment;
  final double monthlyTax;
  final double monthlyPayment;
  final double totalOfPayments;
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
