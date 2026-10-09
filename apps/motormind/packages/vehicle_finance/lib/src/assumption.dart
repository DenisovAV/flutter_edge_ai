/// ISO-8601 date the bundled assumption text and the default rates in this
/// package were last reviewed.
///
/// Every assumption the package builds for itself (tax and fee echoes, the
/// lease residual, the ownership tables, the affordability policy) carries
/// this date so the UI's "as of" labels move together. Bump it whenever a
/// default value or a description is changed.
const String assumptionsReviewedOn = '2026-10-04';

/// A stated assumption behind a computed result.
///
/// Assumptions are what let the UI say "this number assumes X" and what let the
/// model explain what would change the answer. Each one names where it came
/// from and when it was last checked.
class Assumption {
  /// Creates an assumption; [illustrative] defaults to true because most values
  /// worth stating are placeholders or averages rather than quotes.
  const Assumption({
    required this.key,
    required this.description,
    required this.value,
    required this.source,
    required this.asOf,
    this.illustrative = true,
  });

  /// Stable machine key, e.g. `apr.used.prime`.
  final String key;

  /// Plain-language description shown to the user.
  final String description;

  /// The value used, as a string so it can be rendered without knowing its type.
  final String value;

  /// Where the value came from. "user" when the user supplied it.
  final String source;

  /// ISO-8601 date the value was last verified.
  final String asOf;

  /// True when the value is a placeholder or national average rather than a
  /// quote for this user.
  final bool illustrative;

  /// Serializes the assumption for tool results and logs, one key per field.
  Map<String, Object?> toJson() => {
    'key': key,
    'description': description,
    'value': value,
    'source': source,
    'asOf': asOf,
    'illustrative': illustrative,
  };
}

/// Base type for every computed result.
///
/// [inputs] is the exact input set, serialized, so the narration guard can
/// verify any number the model repeats. [assumptions] are rendered beside the
/// numbers.
abstract class CalcResult {
  /// Creates a result from the serialized [inputs] it was computed from and the
  /// [assumptions] it relied on.
  const CalcResult({required this.inputs, required this.assumptions});

  /// The exact inputs the result was computed from, as JSON-compatible values.
  final Map<String, Object?> inputs;

  /// Every assumption the computation relied on, in the order it was applied.
  final List<Assumption> assumptions;

  /// Result fields only, without inputs and assumptions.
  Map<String, Object?> outputsToJson();

  /// Serializes the whole result as `inputs`, `outputs` and `assumptions`, the
  /// shape both the narration guard and the UI read.
  Map<String, Object?> toJson() => {
    'inputs': inputs,
    'outputs': outputsToJson(),
    'assumptions': [for (final a in assumptions) a.toJson()],
  };
}
