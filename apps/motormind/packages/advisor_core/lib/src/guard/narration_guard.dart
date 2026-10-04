/// A number the model wrote, with where it appeared.
class NumberMention {
  const NumberMention({required this.raw, required this.value, required this.offset});

  final String raw;
  final double value;
  final int offset;

  @override
  String toString() => '$raw@$offset';
}

class GuardReport {
  const GuardReport({required this.mentions, required this.unmatched});

  final List<NumberMention> mentions;
  final List<NumberMention> unmatched;

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
  const NarrationGuard({
    this.relativeTolerance = 0.02,
    this.allowSmallIntegersUpTo = 12,
    this.allowYearsFrom = 1980,
    this.allowYearsTo = 2040,
  });

  final double relativeTolerance;
  final int allowSmallIntegersUpTo;
  final int allowYearsFrom;
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

  GuardReport check({required String narration, required Iterable<Object?> sources}) {
    final allowed = allowedValues(sources);
    final mentions = extract(narration);
    final unmatched = [for (final m in mentions) if (!_matches(m.value, allowed)) m];
    return GuardReport(mentions: mentions, unmatched: unmatched);
  }
}
