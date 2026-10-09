/// Kinds of sales language the [PolicyCheck] looks for.
enum PolicyCategory {
  /// Pressure to act quickly ("act now", "today only").
  urgency,

  /// Promised outcomes ("guaranteed approval", "no risk").
  guarantee,

  /// Telling the person what to do ("you need to buy", "best deal").
  pressure,

  /// A recommendation to buy, lease or finance, which Motormind never gives.
  advice,

  /// Wording that implies a partner, referral or commission relationship.
  compensation,
}

/// One match of a policy rule in a reply.
class PolicyFlag {
  /// Creates a flag for [category] with the matched [excerpt].
  const PolicyFlag({required this.category, required this.excerpt});

  /// Which kind of sales language matched.
  final PolicyCategory category;

  /// The matched text with up to [PolicyCheck.excerptContext] characters of
  /// context on each side.
  final String excerpt;

  @override
  String toString() => '${category.name}: "$excerpt"';
}

/// Flags sales language in a reply. Per the product decision (TQ15), flags are
/// surfaced as a banner, not used to block the reply; the system prompt and
/// the disclosures carry the policy, this is the smoke detector.
class PolicyCheck {
  /// Creates a check with the built-in rules.
  const PolicyCheck();

  /// Characters of surrounding text kept on each side of a match in
  /// [PolicyFlag.excerpt]; enough to read the phrase in context on a banner.
  static const int excerptContext = 20;

  static final List<(PolicyCategory, RegExp)> _rules = [
    (
      PolicyCategory.urgency,
      RegExp(
        r"\b(act now|today only|limited time|won't last|don't wait|before it'?s gone|hurry)\b",
        caseSensitive: false,
      ),
    ),
    (
      PolicyCategory.guarantee,
      RegExp(
        r"\b(guarantee[ds]?|guaranteed approval|you will be approved|promise[sd]?|no risk|risk[- ]free|can\'?t lose)\b",
        caseSensitive: false,
      ),
    ),
    (
      // "best deal of the three" compares results the person asked for;
      // "the best deal" sells. The lookahead keeps the comparison.
      PolicyCategory.pressure,
      RegExp(
        r'\b(you (?:should|need to|have to|must) (?:buy|lease|sign|finance)|(?:great|best) deal\b(?! of )|steal|no[- ]brainer|once[- ]in[- ]a[- ]lifetime)\b',
        caseSensitive: false,
      ),
    ),
    (
      PolicyCategory.advice,
      RegExp(
        r"\b(i recommend (?:you )?(?:buy|lease|finance)|my advice is to (?:buy|lease)|you can(?:not|\'t) go wrong)\b",
        caseSensitive: false,
      ),
    ),
    (
      PolicyCategory.compensation,
      RegExp(
        r"\b(our (?:partner|preferred) (?:lender|dealer)|we(?:\'ll| will) (?:get|earn)|refer(?:ral)? (?:fee|bonus))\b",
        caseSensitive: false,
      ),
    ),
  ];

  /// Returns every rule match in [narration], grouped by category in rule
  /// order; empty when the text is clean.
  List<PolicyFlag> check(String narration) {
    final flags = <PolicyFlag>[];
    for (final (category, rule) in _rules) {
      for (final m in rule.allMatches(narration)) {
        final start = (m.start - excerptContext).clamp(0, narration.length);
        final end = (m.end + excerptContext).clamp(0, narration.length);
        flags.add(PolicyFlag(category: category, excerpt: narration.substring(start, end).trim()));
      }
    }
    return flags;
  }
}
