import 'assumption.dart';
import 'money.dart';

/// Trade-in equity: what the vehicle is worth minus what is owed on it.
///
/// Negative equity is reported plainly; it is the single most important
/// number for a buyer who still owes on their current vehicle.
class TradeEquity extends CalcResult {
  /// Creates the result from the two user-supplied figures; [tradeEquity]
  /// validates them first and is the usual way to get one.
  TradeEquity({required this.estimatedValue, required this.payoff, required super.assumptions})
    : super(inputs: {'estimatedValue': estimatedValue, 'payoff': payoff});

  /// What the current vehicle is expected to fetch in trade, in dollars.
  final double estimatedValue;

  /// Remaining loan balance on the current vehicle, in dollars; zero when it is
  /// owned outright.
  final double payoff;

  /// [estimatedValue] minus [payoff], in dollars; negative when the vehicle is
  /// underwater.
  double get equity => roundCents(estimatedValue - payoff);

  /// True when more is owed on the vehicle than it is worth.
  bool get isNegative => equity < 0;

  /// Negative equity as a positive amount, zero when equity is positive.
  double get shortfall => isNegative ? -equity : 0;

  @override
  Map<String, Object?> outputsToJson() => {
    'equity': equity,
    'isNegative': isNegative,
    'shortfall': shortfall,
  };
}

/// Computes trade-in equity from an estimated value and a loan payoff, both in
/// dollars; [valueAssumption] records where the value estimate came from.
///
/// Throws an [ArgumentError] when either figure is negative.
TradeEquity tradeEquity({
  required double estimatedValue,
  required double payoff,
  required Assumption valueAssumption,
}) {
  if (estimatedValue < 0) {
    throw ArgumentError.value(estimatedValue, 'estimatedValue', 'must not be negative');
  }
  if (payoff < 0) throw ArgumentError.value(payoff, 'payoff', 'must not be negative');
  return TradeEquity(
    estimatedValue: estimatedValue,
    payoff: payoff,
    assumptions: [valueAssumption],
  );
}
