import 'dart:math' as math;

import 'assumption.dart';
import 'loan.dart';
import 'money.dart';
import 'trade.dart';

/// Everything needed to estimate a financed purchase.
///
/// Money fields are in dollars and rates are fractions. The defaults describe
/// the simplest deal: no tax, no fees, nothing down and no trade-in.
class DealInputs {
  /// Creates the inputs; only [price], [apr] and [termMonths] are required.
  const DealInputs({
    required this.price,
    required this.apr,
    required this.termMonths,
    this.salesTaxRate = 0,
    this.fees = 0,
    this.downPayment = 0,
    this.trade,
    this.rollNegativeEquity = true,
    this.taxCreditForTrade = false,
  });

  /// Agreed vehicle price before tax and fees, in dollars.
  final double price;

  /// Decimal APR, `0.065` for 6.5%.
  final double apr;

  /// Length of the loan in months.
  final int termMonths;

  /// Decimal sales tax rate, `0.07` for 7%.
  final double salesTaxRate;

  /// Doc, title, registration and dealer fees, summed.
  final double fees;

  /// Cash paid at signing toward the purchase, in dollars.
  final double downPayment;

  /// Equity position of the current vehicle, or null when nothing is traded in.
  final TradeEquity? trade;

  /// When the trade is underwater, finance the shortfall (true) or pay it in
  /// cash at signing (false).
  final bool rollNegativeEquity;

  /// Some states tax only the difference between price and trade value. Off
  /// by default; the app sets it from the state table when known.
  final bool taxCreditForTrade;

  /// Serializes the inputs as flat JSON; the trade is reduced to its value and
  /// payoff so the result's inputs stay one level deep.
  Map<String, Object?> toJson() => {
    'price': price,
    'apr': apr,
    'termMonths': termMonths,
    'salesTaxRate': salesTaxRate,
    'fees': fees,
    'downPayment': downPayment,
    'tradeEstimatedValue': trade?.estimatedValue,
    'tradePayoff': trade?.payoff,
    'rollNegativeEquity': rollNegativeEquity,
    'taxCreditForTrade': taxCreditForTrade,
  };

  /// Returns a copy with the given fields replaced, which is how one-variable
  /// alternatives to a deal are built. Passing null for [trade] keeps the
  /// existing trade rather than clearing it.
  DealInputs copyWith({
    double? price,
    double? apr,
    int? termMonths,
    double? salesTaxRate,
    double? fees,
    double? downPayment,
    TradeEquity? trade,
    bool? rollNegativeEquity,
    bool? taxCreditForTrade,
  }) => DealInputs(
    price: price ?? this.price,
    apr: apr ?? this.apr,
    termMonths: termMonths ?? this.termMonths,
    salesTaxRate: salesTaxRate ?? this.salesTaxRate,
    fees: fees ?? this.fees,
    downPayment: downPayment ?? this.downPayment,
    trade: trade ?? this.trade,
    rollNegativeEquity: rollNegativeEquity ?? this.rollNegativeEquity,
    taxCreditForTrade: taxCreditForTrade ?? this.taxCreditForTrade,
  );
}

/// A complete purchase estimate in the consumer layout: what you pay at
/// signing, what you finance, what it costs per month, what it costs in total.
///
/// Every field is in dollars, rounded to the cent.
class DealEstimate extends CalcResult {
  /// Creates an estimate from already-computed figures; [estimateDeal] is the
  /// usual way to get one. The [deal] inputs are serialized into [inputs].
  DealEstimate({
    required DealInputs deal,
    required this.salesTax,
    required this.tradeEquityApplied,
    required this.negativeEquityFinanced,
    required this.cashDueAtSigning,
    required this.cashBack,
    required this.amountFinanced,
    required this.monthlyPayment,
    required this.totalOfPayments,
    required this.financeCharge,
    required this.totalCost,
    required this.schedule,
    required super.assumptions,
  }) : super(inputs: deal.toJson());

  /// Sales tax on the full price, or on price minus trade value when
  /// [DealInputs.taxCreditForTrade] is set.
  final double salesTax;

  /// Positive equity credited toward the purchase (zero if none). When the
  /// equity is worth more than the deal needs, only the part that was needed
  /// is here and the rest is [cashBack].
  final double tradeEquityApplied;

  /// Negative equity added to the loan (zero if paid in cash or none).
  final double negativeEquityFinanced;

  /// Down payment plus any negative equity paid in cash. Never negative: a
  /// down payment larger than the deal is simply not collected in full.
  final double cashDueAtSigning;

  /// Positive trade equity left over after the whole deal is covered, which
  /// the dealer owes the buyer (zero in the usual case). Reported separately
  /// so it is never hidden inside a negative [cashDueAtSigning].
  final double cashBack;

  /// Loan principal: price, tax and fees, less down payment and positive
  /// equity, plus any financed negative equity. Never negative.
  final double amountFinanced;

  /// Regular monthly payment on [amountFinanced], from the amortization formula.
  final double monthlyPayment;

  /// Sum of every scheduled payment over the term.
  final double totalOfPayments;

  /// Interest paid over the life of the loan: [totalOfPayments] minus
  /// [amountFinanced].
  final double financeCharge;

  /// Cash at signing plus total of payments; [cashBack] is not netted out.
  final double totalCost;

  /// Month-by-month amortization of [amountFinanced], for the payoff chart.
  /// Kept out of [outputsToJson] because the narration guard verifies the
  /// headline figures, not sixty rows the model never repeats.
  final List<AmortizationRow> schedule;

  @override
  Map<String, Object?> outputsToJson() => {
    'salesTax': salesTax,
    'tradeEquityApplied': tradeEquityApplied,
    'negativeEquityFinanced': negativeEquityFinanced,
    'cashDueAtSigning': cashDueAtSigning,
    'cashBack': cashBack,
    'amountFinanced': amountFinanced,
    'monthlyPayment': monthlyPayment,
    'totalOfPayments': totalOfPayments,
    'financeCharge': financeCharge,
    'totalCost': totalCost,
  };
}

/// Estimates a financed purchase from [deal]: sales tax on the taxable price,
/// then fees, down payment and trade equity applied to reach the amount
/// financed, which is amortized over the term for the payment, the total of
/// payments and the schedule.
///
/// When cash and equity exceed what the deal needs, nothing is financed; the
/// surplus comes first out of the down payment, which is not collected in
/// full, and any equity still left over is reported as
/// [DealEstimate.cashBack]. The result carries [aprAssumption], the tax and
/// fee inputs as non-illustrative assumptions, and any assumptions attached
/// to the trade.
///
/// Throws an [ArgumentError] for a negative price or down payment; the loan
/// arguments are validated by [monthlyPayment].
DealEstimate estimateDeal(DealInputs deal, {required Assumption aprAssumption}) {
  if (deal.price < 0) {
    throw ArgumentError.value(deal.price, 'price', 'must not be negative');
  }
  if (deal.downPayment < 0) {
    throw ArgumentError.value(deal.downPayment, 'downPayment', 'must not be negative');
  }
  final salesTax = _salesTaxFor(deal);
  final financing = _financing(deal, salesTax: salesTax);
  final financed = financing.amountFinanced;

  final payment = monthlyPayment(principal: financed, apr: deal.apr, termMonths: deal.termMonths);
  final schedule = amortizationSchedule(
    principal: financed,
    apr: deal.apr,
    termMonths: deal.termMonths,
  );
  final total = roundCents(schedule.fold<double>(0, (sum, row) => sum + row.payment));

  return DealEstimate(
    deal: deal,
    salesTax: salesTax,
    tradeEquityApplied: financing.equityApplied,
    negativeEquityFinanced: financing.negativeEquityFinanced,
    cashDueAtSigning: financing.cashDueAtSigning,
    cashBack: financing.cashBack,
    amountFinanced: financed,
    monthlyPayment: payment,
    totalOfPayments: total,
    financeCharge: roundCents(total - financed),
    totalCost: roundCents(financing.cashDueAtSigning + total),
    schedule: schedule,
    assumptions: _dealAssumptions(deal, aprAssumption: aprAssumption),
  );
}

/// Sales tax on the full price, or on the price less the trade value when the
/// state credits the trade; the taxable base never goes below zero.
double _salesTaxFor(DealInputs deal) {
  final trade = deal.trade;
  final taxable = deal.taxCreditForTrade && trade != null
      ? math.max(0.0, deal.price - trade.estimatedValue)
      : deal.price;
  return roundCents(taxable * deal.salesTaxRate);
}

/// The money that changes hands at signing, split the way the estimate
/// reports it. Every figure is rounded to the cent.
typedef _Financing = ({
  double amountFinanced,
  double cashDueAtSigning,
  double cashBack,
  double equityApplied,
  double negativeEquityFinanced,
});

/// Applies down payment and trade equity to price, tax and fees.
///
/// A positive remainder is financed. A negative one means the buyer brought
/// more than the deal needs: the down payment is reduced first, since nobody
/// hands over cash to get it straight back, and any equity still left over is
/// cash back from the dealer.
_Financing _financing(DealInputs deal, {required double salesTax}) {
  final trade = deal.trade;
  final positiveEquity = trade != null && !trade.isNegative ? trade.equity : 0.0;
  final shortfall = trade?.shortfall ?? 0.0;
  final negativeFinanced = deal.rollNegativeEquity ? shortfall : 0.0;
  final negativeInCash = deal.rollNegativeEquity ? 0.0 : shortfall;

  final remainder =
      deal.price + salesTax + deal.fees - deal.downPayment - positiveEquity + negativeFinanced;
  final surplus = math.max(0.0, -remainder);
  final uncollectedDown = math.min(surplus, deal.downPayment);
  final cashBack = surplus - uncollectedDown;

  return (
    amountFinanced: roundCents(math.max(0.0, remainder)),
    cashDueAtSigning: roundCents(deal.downPayment - uncollectedDown + negativeInCash),
    cashBack: roundCents(cashBack),
    equityApplied: roundCents(positiveEquity - cashBack),
    negativeEquityFinanced: roundCents(negativeFinanced),
  );
}

/// The assumptions a deal estimate carries, in the order they are applied:
/// the caller's APR assumption, the tax rate and fees echoed back as
/// non-illustrative ones so the UI can show what the numbers were built on,
/// then whatever the trade-in brought with it.
List<Assumption> _dealAssumptions(DealInputs deal, {required Assumption aprAssumption}) => [
  aprAssumption,
  Assumption(
    key: 'tax.rate',
    description:
        'Sales tax rate applied to the ${deal.taxCreditForTrade ? 'price minus trade value' : 'full price'}.',
    value: '${(deal.salesTaxRate * 100).toStringAsFixed(2)}%',
    source: 'user or state table',
    asOf: assumptionsReviewedOn,
    illustrative: false,
  ),
  Assumption(
    key: 'fees.total',
    description: 'Dealer, documentation, title and registration fees as entered.',
    value: deal.fees.toStringAsFixed(2),
    source: 'user',
    asOf: assumptionsReviewedOn,
    illustrative: false,
  ),
  ...?deal.trade?.assumptions,
];
