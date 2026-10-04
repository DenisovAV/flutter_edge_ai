import 'assumption.dart';
import 'money.dart';

/// Trade-in equity: what the vehicle is worth minus what is owed on it.
///
/// Negative equity is reported plainly; it is the single most important
/// number for a buyer who still owes on their current vehicle.
class TradeEquity extends CalcResult {
  TradeEquity({
    required this.estimatedValue,
    required this.payoff,
    required super.assumptions,
  }) : super(inputs: {'estimatedValue': estimatedValue, 'payoff': payoff});

  final double estimatedValue;
  final double payoff;

  double get equity => roundCents(estimatedValue - payoff);
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
