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
  }) =>
      DealInputs(
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
    required this.amountFinanced,
    required this.monthlyPayment,
    required this.totalOfPayments,
    required this.financeCharge,
    required this.totalCost,
    required super.assumptions,
  }) : super(inputs: deal.toJson());

  /// Sales tax on the full price, or on price minus trade value when
  /// [DealInputs.taxCreditForTrade] is set.
  final double salesTax;

  /// Positive equity credited toward the purchase (zero if none).
  final double tradeEquityApplied;

  /// Negative equity added to the loan (zero if paid in cash or none).
  final double negativeEquityFinanced;

  /// Down payment plus any negative equity paid in cash.
  final double cashDueAtSigning;

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

  /// Cash at signing plus total of payments.
  final double totalCost;

  @override
  Map<String, Object?> outputsToJson() => {
        'salesTax': salesTax,
        'tradeEquityApplied': tradeEquityApplied,
        'negativeEquityFinanced': negativeEquityFinanced,
        'cashDueAtSigning': cashDueAtSigning,
        'amountFinanced': amountFinanced,
        'monthlyPayment': monthlyPayment,
        'totalOfPayments': totalOfPayments,
        'financeCharge': financeCharge,
        'totalCost': totalCost,
      };
}

/// Estimates a financed purchase from [deal], applying tax, fees, down payment
/// and trade equity before amortizing the remainder over the term.
///
/// When cash and equity exceed what the deal needs, nothing is financed and
/// the surplus down payment is simply not collected. The result carries
/// [aprAssumption], the tax and fee inputs as non-illustrative assumptions,
/// and any assumptions attached to the trade.
///
/// Throws an [ArgumentError] for a negative price or down payment; the loan
/// arguments are validated by [monthlyPayment].
DealEstimate estimateDeal(DealInputs deal, {required Assumption aprAssumption}) {
  if (deal.price < 0) throw ArgumentError.value(deal.price, 'price', 'must not be negative');
  if (deal.downPayment < 0) {
    throw ArgumentError.value(deal.downPayment, 'downPayment', 'must not be negative');
  }
  final trade = deal.trade;
  final taxable = deal.taxCreditForTrade && trade != null
      ? (deal.price - trade.estimatedValue).clamp(0, double.infinity).toDouble()
      : deal.price;
  final salesTax = roundCents(taxable * deal.salesTaxRate);

  final positiveEquity = trade != null && !trade.isNegative ? trade.equity : 0.0;
  final shortfall = trade?.shortfall ?? 0.0;
  final negativeFinanced = deal.rollNegativeEquity ? shortfall : 0.0;
  final negativeInCash = deal.rollNegativeEquity ? 0.0 : shortfall;

  var financed = deal.price + salesTax + deal.fees - deal.downPayment - positiveEquity + negativeFinanced;
  var cashAtSigning = deal.downPayment + negativeInCash;
  if (financed < 0) {
    // More cash and equity than the deal needs: nothing is financed and the
    // excess down payment is not collected.
    cashAtSigning = roundCents(cashAtSigning + financed);
    financed = 0;
  }
  financed = roundCents(financed);
  cashAtSigning = roundCents(cashAtSigning);

  final payment = monthlyPayment(principal: financed, apr: deal.apr, termMonths: deal.termMonths);
  final schedule = amortizationSchedule(principal: financed, apr: deal.apr, termMonths: deal.termMonths);
  final total = roundCents(schedule.fold<double>(0, (sum, row) => sum + row.payment));

  final assumptions = <Assumption>[
    aprAssumption,
    Assumption(
      key: 'tax.rate',
      description: 'Sales tax rate applied to the ${deal.taxCreditForTrade ? 'price minus trade value' : 'full price'}.',
      value: '${(deal.salesTaxRate * 100).toStringAsFixed(2)}%',
      source: 'user or state table',
      asOf: '2026-10-04',
      illustrative: false,
    ),
    Assumption(
      key: 'fees.total',
      description: 'Dealer, documentation, title and registration fees as entered.',
      value: deal.fees.toStringAsFixed(2),
      source: 'user',
      asOf: '2026-10-04',
      illustrative: false,
    ),
    if (trade != null) ...trade.assumptions,
  ];

  return DealEstimate(
    deal: deal,
    salesTax: salesTax,
    tradeEquityApplied: roundCents(positiveEquity),
    negativeEquityFinanced: roundCents(negativeFinanced),
    cashDueAtSigning: cashAtSigning,
    amountFinanced: financed,
    monthlyPayment: payment,
    totalOfPayments: total,
    financeCharge: roundCents(total - financed),
    totalCost: roundCents(cashAtSigning + total),
    assumptions: assumptions,
  );
}
