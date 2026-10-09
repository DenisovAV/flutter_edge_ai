/// A number found in text, with its original spelling and position.
class NumberMention {
  /// Creates a mention of [raw], parsed as [value], found at [offset].
  const NumberMention({required this.raw, required this.value, required this.offset});

  /// The text as written, including any `$`, thousands separators, `%` or
  /// `k` suffix.
  final String raw;

  /// The parsed value. A percentage is stored as a fraction (`7%` is 0.07)
  /// and a `k` suffix is expanded (`22k` is 22000).
  final double value;

  /// Zero-based character offset of [raw] in the text it came from.
  final int offset;

  @override
  String toString() => '$raw@$offset';
}

/// The outcome of a [NarrationGuard.check]: every number in the reply and the
/// subset that matched no tool result or user input.
class GuardReport {
  /// Creates a report from all [mentions] and the [unmatched] subset.
  const GuardReport({required this.mentions, required this.unmatched});

  /// Every number found in the narration, in document order.
  final List<NumberMention> mentions;

  /// The mentions that matched nothing in the sources; empty when [passed].
  final List<NumberMention> unmatched;

  /// True when every number in the narration traced to a source.
  bool get passed => unmatched.isEmpty;
}

/// Enforces "numbers come from tools, not from the model."
///
/// Every number in a reply must match a number in the turn's tool results or
/// the user's own inputs. Matching is tolerant of formatting (`$1,234.50`
/// vs `1234.5`), of rounding to whole dollars, and of a small relative
/// difference for spoken rounding ("about $480" for 483.32). Years and small
/// counts are allowed through because they are not financial claims.
class NarrationGuard {
  /// Creates a guard; the defaults allow 2% spoken rounding, counts up to 12
  /// and model years from 1980 to 2040 without a source.
  const NarrationGuard({
    this.relativeTolerance = 0.02,
    this.allowSmallIntegersUpTo = 12,
    this.allowYearsFrom = 1980,
    this.allowYearsTo = 2040,
  });

  /// Largest relative difference, as a fraction of the source value, between
  /// a written number and a source value that still counts as a match.
  final double relativeTolerance;

  /// Whole numbers from zero up to this value pass without a source, since
  /// counts such as "3 options" are not financial claims.
  final int allowSmallIntegersUpTo;

  /// First whole number treated as a model year and passed without a source.
  final int allowYearsFrom;

  /// Last whole number treated as a model year and passed without a source.
  final int allowYearsTo;

  static final RegExp _numberPattern = RegExp(
    r'(?<!\w)[\$]?\d{1,3}(?:,\d{3})+(?:\.\d+)?%?|(?<!\w)[\$]?\d+(?:\.\d+)?%?(?:\s?[kK](?!\w))?',
  );

  /// Extracts numeric mentions from [text].
  List<NumberMention> extract(String text) {
    final out = <NumberMention>[];
    for (final m in _numberPattern.allMatches(text)) {
      final raw = m.group(0)!;
      var cleaned = raw.replaceAll(RegExp(r'[\$,%\s]'), '');
      var multiplier = 1.0;
      if (cleaned.endsWith('k') || cleaned.endsWith('K')) {
        cleaned = cleaned.substring(0, cleaned.length - 1);
        multiplier = 1000;
      }
      final v = double.tryParse(cleaned);
      if (v == null) continue;
      var value = v * multiplier;
      if (raw.endsWith('%')) value = v / 100;
      out.add(NumberMention(raw: raw, value: value, offset: m.start));
    }
    return out;
  }

  /// Collects every number reachable in [sources] (tool results, user inputs),
  /// including nested maps and lists, numeric strings and percent strings.
  Set<double> allowedValues(Iterable<Object?> sources) {
    final out = <double>{};
    void walk(Object? v) {
      if (v is num) {
        out.add(v.toDouble());
      } else if (v is String) {
        for (final m in extract(v)) {
          out.add(m.value);
        }
      } else if (v is Map) {
        v.values.forEach(walk);
      } else if (v is Iterable) {
        v.forEach(walk);
      }
    }

    sources.forEach(walk);
    // A percentage in results may be narrated as a decimal or vice versa.
    for (final v in out.toList()) {
      if (v > 0 && v < 1) out.add(v * 100);
      if (v >= 1 && v <= 100) out.add(v / 100);
    }
    return out;
  }

  bool _matches(double mention, Set<double> allowed) {
    final asInt = mention.roundToDouble() == mention;
    if (asInt && mention >= 0 && mention <= allowSmallIntegersUpTo) return true;
    if (asInt && mention >= allowYearsFrom && mention <= allowYearsTo) return true;
    for (final a in allowed) {
      if (a == mention) return true;
      if (a.round() == mention.round()) return true;
      final scale = a.abs() < 1 ? 1 : a.abs();
      if ((a - mention).abs() / scale <= relativeTolerance) return true;
    }
    return false;
  }

  /// Checks every number in [narration] against the values reachable in
  /// [sources]; see [allowedValues] for what counts as a source.
  GuardReport check({required String narration, required Iterable<Object?> sources}) {
    final allowed = allowedValues(sources);
    final mentions = extract(narration);
    final unmatched = [
      for (final m in mentions)
        if (!_matches(m.value, allowed)) m,
    ];
    return GuardReport(mentions: mentions, unmatched: unmatched);
  }
}
