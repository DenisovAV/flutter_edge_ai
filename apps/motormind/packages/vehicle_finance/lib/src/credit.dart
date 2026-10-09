import 'assumption.dart';

/// Credit bands shown to the user. Score ranges follow the VantageScore tiers
/// commonly used in auto-finance reporting (super prime through deep subprime),
/// relabeled in plain language.
enum CreditBand {
  /// Super-prime scores, 781–850.
  excellent(781, 850, 'Excellent'),

  /// Prime scores, 661–780.
  good(661, 780, 'Good'),

  /// Near-prime scores, 601–660.
  fair(601, 660, 'Fair'),

  /// Subprime scores, 501–600.
  poor(501, 600, 'Poor'),

  /// Deep-subprime scores, 300–500.
  rebuilding(300, 500, 'Rebuilding');

  /// Defines a band by its inclusive score range and its user-facing label.
  const CreditBand(this.minScore, this.maxScore, this.label);

  /// Lowest score in the band, inclusive.
  final int minScore;

  /// Highest score in the band, inclusive.
  final int maxScore;

  /// Plain-language name shown to the user in place of the industry tier name.
  final String label;

  /// Parses a band name as written by a tool call or a stored profile, ignoring
  /// case and surrounding whitespace.
  ///
  /// Throws an [ArgumentError] for anything that is not one of [values].
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
  /// Creates the new/used rate pair for one credit band.
  const AprRates({required this.newVehicle, required this.usedVehicle});

  /// APR for financing a new vehicle, as a fraction (0.0441 for 4.41%).
  final double newVehicle;

  /// APR for financing a used vehicle, as a fraction (0.0629 for 6.29%).
  final double usedVehicle;

  /// Selects [newVehicle] or [usedVehicle] by the vehicle's condition.
  double forCondition({required bool isNew}) => isNew ? newVehicle : usedVehicle;

  /// Serializes as `{"new": ..., "used": ...}`, the layout of the bundled table.
  Map<String, Object?> toJson() => {'new': newVehicle, 'used': usedVehicle};

  /// Reads a rate pair back from the layout [toJson] writes.
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
  /// Creates a table; [illustrative] defaults to true because a table of
  /// averages is never a quote.
  const AprTable({
    required this.source,
    required this.asOf,
    required this.rates,
    this.illustrative = true,
  });

  /// Where the rates came from, in a form that can be shown beside them.
  final String source;

  /// ISO-8601 date the rates were last verified; shown beside every rate.
  final String asOf;

  /// True when the rates are averages or placeholders rather than quotes for
  /// this user.
  final bool illustrative;

  /// Rates by band; every band [creditBandForScore] can return should be
  /// present, since [aprFor] throws on a missing one.
  final Map<CreditBand, AprRates> rates;

  /// Looks up the APR for [band] on a new or used vehicle, as a fraction.
  ///
  /// Throws a [StateError] when the table has no entry for [band].
  double aprFor(CreditBand band, {required bool isNew}) {
    final r = rates[band];
    if (r == null) throw StateError('no rate for ${band.name}');
    return r.forCondition(isNew: isNew);
  }

  /// Builds the [Assumption] that documents the rate [aprFor] returns, so a
  /// loan or deal estimate carries the source and date of its APR.
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

  /// Serializes the table in the bundled JSON layout, keyed by band name.
  Map<String, Object?> toJson() => {
        'source': source,
        'asOf': asOf,
        'illustrative': illustrative,
        'rates': {for (final e in rates.entries) e.key.name: e.value.toJson()},
      };

  /// Reads a table from the layout [toJson] writes; `illustrative` defaults to
  /// true when the file omits it.
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
