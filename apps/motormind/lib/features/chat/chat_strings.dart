/// Every sentence the chat shows the person, in one place, so wording is a
/// reviewable diff rather than a scavenger hunt (the same rule disclosures
/// follow in `advisor_core`).
abstract final class ChatStrings {
  static const noModel = 'No model is loaded. Open Models and choose one.';
  static const startFailed = 'Motormind could not start.';
  static const tooLong = 'Motormind took too long to answer.';
  static const contextFull =
      'The conversation grew past what this model can hold in memory. Start a new conversation '
      'to continue.';
  static const somethingWrong = 'Something went wrong.';
  static const numbersReplaced =
      'Motormind\'s wording was replaced because it contained numbers not from a calculation.';
  static const nothingToAdd =
      'Nothing to add yet. Pick an option above, change a filter, or tell me more.';
  static const hereIsWhatIFound = 'Here is what I found. Tell me more when you are ready.';
  static const policyBanner =
      'Motormind does not sell or promise. This reply tripped the sales-language check';
  static const askMotormind = 'Ask Motormind';
  static const starting = 'Starting…';
  static const showSoFar = 'Show what you have so far';
  static const hintPending = 'Something else? Type it here…';
  static const hintFiltered = 'Tell me more: must-haves, a budget, a trade-in…';
  static const hintDefault = 'Tell me about the car you have in mind…';

  static String stoppedAfter(int seconds) =>
      'Stopped: Motormind went $seconds seconds without a word. Try a shorter message.';

  static String refusedInputs(Iterable<String> arguments) =>
      'Refused a calculation: ${arguments.join(', ')} was not something you told me.';

  static String checkingNumbers(Iterable<String> raw) => 'Checking numbers: ${raw.join(', ')}';

  static String noMatches(String site, String query) =>
      'Nothing on $site matched $query. Loosen a filter or try another site.';

  static String matches(int count, String site, String query) =>
      '$count ${count == 1 ? 'listing' : 'listings'} on $site match $query. '
      'Tap a type or price to narrow it, or tell me more.';

  static String searchNote(String query, String site, int matched) =>
      'Looking for $query on $site: $matched matched.';

  static String monthlyCostOf(String title) => 'What would the $title cost me a month?';
}
