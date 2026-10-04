enum PolicyCategory { urgency, guarantee, pressure, advice, compensation }

class PolicyFlag {
  const PolicyFlag({required this.category, required this.excerpt, required this.pattern});

  final PolicyCategory category;
  final String excerpt;
  final String pattern;

  @override
  String toString() => '${category.name}: "$excerpt"';
}

/// Flags sales language in a reply. Per the product decision (TQ15), flags are
/// surfaced as a banner, not used to block the reply; the system prompt and
/// the disclosures carry the policy, this is the smoke detector.
class PolicyCheck {
  const PolicyCheck();

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
      PolicyCategory.pressure,
      RegExp(
        r'\b(you (?:should|need to|have to|must) (?:buy|lease|sign|finance)|great deal|best deal|steal|no[- ]brainer|once[- ]in[- ]a[- ]lifetime)\b',
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

  List<PolicyFlag> check(String narration) {
    final flags = <PolicyFlag>[];
    for (final (category, rule) in _rules) {
      for (final m in rule.allMatches(narration)) {
        final start = m.start - 20 < 0 ? 0 : m.start - 20;
        final end = m.end + 20 > narration.length ? narration.length : m.end + 20;
        flags.add(
          PolicyFlag(
            category: category,
            excerpt: narration.substring(start, end).trim(),
            pattern: rule.pattern,
          ),
        );
      }
    }
    return flags;
  }
}
