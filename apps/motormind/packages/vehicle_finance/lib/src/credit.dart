import 'assumption.dart';

/// Credit bands shown to the user. Score ranges follow the VantageScore tiers
/// commonly used in auto-finance reporting (super prime through deep subprime),
/// relabeled in plain language.
enum CreditBand {
  excellent(781, 850, 'Excellent'),
  good(661, 780, 'Good'),
  fair(601, 660, 'Fair'),
  poor(501, 600, 'Poor'),
  rebuilding(300, 500, 'Rebuilding');

  const CreditBand(this.minScore, this.maxScore, this.label);

  final int minScore;
  final int maxScore;
  final String label;

  static CreditBand parse(String value) => CreditBand.values.firstWhere(
        (b) => b.name == value.toLowerCase().trim(),
        orElse: () => throw ArgumentError.value(value, 'value', 'unknown credit band'),
      );
}

/// Maps a numeric score to a band. Scores outside 300–850 are clamped.
CreditBand creditBandForScore(int score) {
  final s = score < 300 ? 300 : (score > 850 ? 850 : score);
  return CreditBand.values.firstWhere((b) => s >= b.minScore && s <= b.maxScore);
}

/// Illustrative APRs for one band, as decimals.
class AprRates {
  const AprRates({required this.newVehicle, required this.usedVehicle});

  final double newVehicle;
  final double usedVehicle;

  double forCondition({required bool isNew}) => isNew ? newVehicle : usedVehicle;

  Map<String, Object?> toJson() => {'new': newVehicle, 'used': usedVehicle};

  factory AprRates.fromJson(Map<String, Object?> json) => AprRates(
        newVehicle: (json['new'] as num).toDouble(),
        usedVehicle: (json['used'] as num).toDouble(),
      );
}

/// A dated, sourced table of illustrative APRs by credit band.
///
/// The app ships one as a bundled JSON file and shows its `asOf` date beside
/// every rate. Nothing here is a quote.
class AprTable {
  const AprTable({
    required this.source,
    required this.asOf,
    required this.rates,
    this.illustrative = true,
  });

  final String source;
  final String asOf;
  final bool illustrative;
  final Map<CreditBand, AprRates> rates;

  double aprFor(CreditBand band, {required bool isNew}) {
    final r = rates[band];
    if (r == null) throw StateError('no rate for ${band.name}');
    return r.forCondition(isNew: isNew);
  }

  Assumption assumptionFor(CreditBand band, {required bool isNew}) {
    final apr = aprFor(band, isNew: isNew);
    final condition = isNew ? 'new' : 'used';
    return Assumption(
      key: 'apr.$condition.${band.name}',
      description:
          'Illustrative APR for a ${band.label.toLowerCase()} credit band on a $condition vehicle. '
          'Your actual rate depends on the lender, the vehicle and your full credit file.',
      value: '${(apr * 100).toStringAsFixed(2)}%',
      source: source,
      asOf: asOf,
      illustrative: illustrative,
    );
  }

  Map<String, Object?> toJson() => {
        'source': source,
        'asOf': asOf,
        'illustrative': illustrative,
        'rates': {for (final e in rates.entries) e.key.name: e.value.toJson()},
      };

  factory AprTable.fromJson(Map<String, Object?> json) {
    final raw = json['rates'] as Map<String, Object?>;
    return AprTable(
      source: json['source'] as String,
      asOf: json['asOf'] as String,
      illustrative: json['illustrative'] as bool? ?? true,
      rates: {
        for (final e in raw.entries)
          CreditBand.parse(e.key): AprRates.fromJson(e.value as Map<String, Object?>),
      },
    );
  }
}

/// Average APRs by credit tier, new and used, from Experian's *State of the
/// Automotive Finance Market*, Q2 2026, as transcribed by the project owner on
/// 2026-10-04. Averages, not quotes: labeled illustrative in every result.
const AprTable experianQ2_2026AprTable = AprTable(
  source: 'Experian State of the Automotive Finance Market, Q2 2026 (averages by tier)',
  asOf: '2026-06-30',
  illustrative: true,
  rates: {
    CreditBand.excellent: AprRates(newVehicle: 0.0441, usedVehicle: 0.0629),
    CreditBand.good: AprRates(newVehicle: 0.0615, usedVehicle: 0.0881),
    CreditBand.fair: AprRates(newVehicle: 0.0971, usedVehicle: 0.1393),
    CreditBand.poor: AprRates(newVehicle: 0.1352, usedVehicle: 0.1910),
    CreditBand.rebuilding: AprRates(newVehicle: 0.1611, usedVehicle: 0.2162),
  },
);

/// The table the app uses unless a newer one is loaded via [AprTable.fromJson].
const AprTable defaultAprTable = experianQ2_2026AprTable;
