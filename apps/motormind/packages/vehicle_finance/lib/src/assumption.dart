/// A stated assumption behind a computed result.
///
/// Assumptions are what let the UI say "this number assumes X" and what let the
/// model explain what would change the answer. Each one names where it came
/// from and when it was last checked.
class Assumption {
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
  const CalcResult({required this.inputs, required this.assumptions});

  final Map<String, Object?> inputs;
  final List<Assumption> assumptions;

  /// Result fields only, without inputs and assumptions.
  Map<String, Object?> outputsToJson();

  Map<String, Object?> toJson() => {
        'inputs': inputs,
        'outputs': outputsToJson(),
        'assumptions': [for (final a in assumptions) a.toJson()],
      };
}
