import 'narration_guard.dart';

/// Where a tool argument's number came from, or that it came from nowhere.
class InputProvenanceReport {
  const InputProvenanceReport({required this.unsupported});

  /// Argument names whose numeric values match nothing the person said,
  /// nothing in the profile, and no earlier tool output.
  final List<String> unsupported;

  bool get passed => unsupported.isEmpty;
}

/// The other half of "numbers come from the user, not the model" (ADR 0002).
///
/// The narration guard checks numbers the model *writes*. This checks numbers
/// the model *passes to tools*: a model that invents an income to run an
/// affordability check, or a price the user never mentioned, produces a
/// correct-looking card from a fabricated input. Numeric arguments to finance
/// tools must trace to the user's own words, the profile, or an earlier tool
/// result. Non-numeric and enum arguments are not checked. Arguments listed in
/// [derivedAllowed] (defaults the model may legitimately choose, such as a
/// term or a tax rate of zero) are exempt.
class InputProvenanceGuard {
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
    this.extractor = const NarrationGuard(),
  });

  final Set<String> derivedAllowed;
  final NarrationGuard extractor;

  InputProvenanceReport check({
    required Map<String, Object?> args,
    required Iterable<Object?> sources,
  }) {
    final allowed = extractor.allowedValues(sources);
    final unsupported = <String>[];
    for (final e in args.entries) {
      if (derivedAllowed.contains(e.key)) continue;
      final v = e.value;
      double? n;
      if (v is num) n = v.toDouble();
      if (v is String) {
        final mentions = extractor.extract(v);
        if (mentions.length == 1 && mentions.single.raw.trim() == v.trim()) {
          n = mentions.single.value;
        }
      }
      if (n == null) continue;
      if (n == 0) continue; // "none" is a statement, not a figure
      if (!_supported(n, allowed)) unsupported.add(e.key);
    }
    return InputProvenanceReport(unsupported: unsupported);
  }

  bool _supported(double n, Set<double> allowed) {
    for (final a in allowed) {
      if (a == n) return true;
      if (a.round() == n.round() && n.abs() >= 1) return true;
      final scale = a.abs() < 1 ? 1 : a.abs();
      if ((a - n).abs() / scale <= 0.02) return true;
      // "22k" vs 22000 and "1.5 million"-style scaling.
      if (a * 1000 == n || n * 1000 == a) return true;
    }
    return false;
  }
}
