import 'narration_guard.dart';

/// The outcome of an [InputProvenanceGuard.check]: which numeric tool
/// arguments could not be traced to anything the person supplied.
class InputProvenanceReport {
  /// Creates a report listing the [unsupported] argument names.
  const InputProvenanceReport({required this.unsupported});

  /// Argument names whose numeric values match nothing the person said,
  /// nothing in the profile, and no earlier tool output.
  final List<String> unsupported;

  /// True when every checked argument traced to a known source.
  bool get passed => unsupported.isEmpty;
}

/// The other half of "numbers come from the user, not the model" (ADR 0002).
///
/// The narration guard checks numbers the model *writes*. This checks numbers
/// the model *passes to tools*: a model that invents an income to run an
/// affordability check, or a price the person never mentioned, produces a
/// correct-looking card from a fabricated input. Numeric arguments to finance
/// tools must trace to the person's own words, the profile, or an earlier tool
/// result. Non-numeric and enum arguments are not checked. Arguments listed in
/// [derivedAllowed] (defaults the model may legitimately choose, such as a
/// term or a tax rate of zero) are exempt, and so is a value of zero: "no
/// down payment" or "nothing owed" is a statement the person can make
/// without naming a figure, and a zero never inflates a result.
class InputProvenanceGuard {
  /// Creates a guard; the defaults exempt the arguments a model may fill in
  /// on its own and reuse the [NarrationGuard] number parser and matcher.
  const InputProvenanceGuard({
    this.derivedAllowed = const {
      'term_months',
      'sales_tax_rate',
      'fees',
      'years',
      'limit',
      'is_new',
      'roll_negative_equity',
    },
    this.narrationGuard = const NarrationGuard(),
  });

  /// Argument names that are never checked because the model may choose them
  /// without the person having supplied a figure.
  final Set<String> derivedAllowed;

  /// Supplies number parsing ([NarrationGuard.extract]), source collection
  /// ([NarrationGuard.allowedValues]) and the tolerance matcher
  /// ([NarrationGuard.matches]), so both guards agree on what "the same
  /// number" means.
  final NarrationGuard narrationGuard;

  /// Checks the numeric values in [args] against every number reachable in
  /// [sources] (user inputs, the profile as JSON, earlier tool results).
  ///
  /// A string argument counts as numeric only when it is a single number such
  /// as `"22k"`. Matching tolerates whole-dollar rounding and the relative
  /// difference the [narrationGuard] allows, plus a thousands scaling
  /// (`22k` against `22000`) because people abbreviate prices that way.
  InputProvenanceReport check({
    required Map<String, Object?> args,
    required Iterable<Object?> sources,
  }) {
    final allowed = narrationGuard.allowedValues(sources);
    final unsupported = <String>[];
    for (final e in args.entries) {
      if (derivedAllowed.contains(e.key)) continue;
      final v = e.value;
      double? n;
      if (v is num) {
        n = v.toDouble();
      } else if (v is String) {
        final mentions = narrationGuard.extract(v);
        if (mentions.length == 1 && mentions.single.raw.trim() == v.trim()) {
          n = mentions.single.value;
        }
      }
      if (n == null || n == 0) continue;
      if (!_supported(n, allowed)) unsupported.add(e.key);
    }
    return InputProvenanceReport(unsupported: unsupported);
  }

  bool _supported(double n, Set<double> allowed) {
    if (narrationGuard.matches(n, allowed)) return true;
    for (final a in allowed) {
      if (a * 1000 == n || n * 1000 == a) return true;
    }
    return false;
  }
}
