/// One disclosure, versioned so a change re-prompts the gate.
class Disclosure {
  const Disclosure({required this.key, required this.version, required this.short, required this.long});

  final String key;
  final int version;

  /// One sentence, shown inline and in the gate summary.
  final String short;

  /// The fuller explanation, shown on the disclosures screen and the web page.
  final String long;
}

/// The single source of disclosure wording. The gate screen, the settings
/// screen, result cards and the hosted web page all read from here.
abstract final class Disclosures {
  static const notAdvice = Disclosure(
    key: 'not_advice',
    version: 1,
    short: 'This is not financial advice.',
    long: 'Motormind AI is an information tool. It shows estimates computed from the numbers you '
        'provide and from stated assumptions. It does not know your full financial situation and '
        'is not a substitute for a licensed advisor, a lender\'s disclosure, or your own judgment.',
  );

  static const notLenderOrDealer = Disclosure(
    key: 'not_lender_or_dealer',
    version: 1,
    short: 'We are not a lender or a dealer.',
    long: 'Motormind AI does not offer credit, sell or lease vehicles, take applications, or pass '
        'your information to any lender or dealer. Nothing here is an offer of credit.',
  );

  static const noCompensation = Disclosure(
    key: 'no_compensation',
    version: 1,
    short: 'We receive no compensation from any purchase, lease or loan.',
    long: 'No one pays Motormind AI when you buy, lease or finance a vehicle, and no vehicle or '
        'lender is ranked higher because of a business relationship. Any advertising in the app is '
        'labeled as such and does not affect results.',
  );

  static const estimatesOnly = Disclosure(
    key: 'estimates_only',
    version: 1,
    short: 'All figures are estimates.',
    long: 'Payments, costs and values are computed from your inputs and from assumptions the app '
        'states next to each result. Actual figures depend on the lender, the vehicle, taxes and fees '
        'in your area, and your full credit file.',
  );

  static const illustrativeRates = Disclosure(
    key: 'illustrative_rates',
    version: 1,
    short: 'Interest rates shown are illustrative, not quotes.',
    long: 'Rates by credit band come from a dated table that is shown beside every rate. They are '
        'typical ranges, not an offer, and you can replace them with a rate you were quoted.',
  );

  static const dataStaysOnDevice = Disclosure(
    key: 'data_on_device',
    version: 1,
    short: 'Your financial information stays on your device.',
    long: 'The assistant runs on your phone. Your income, credit band, trade-in and payment '
        'information are stored only on this device and are never uploaded. Anonymous usage '
        'statistics, if enabled, contain no personal or financial information.',
  );

  static const browserActions = Disclosure(
    key: 'browser_actions',
    version: 1,
    short: 'Web actions require your approval, every time.',
    long: 'The assistant can read web pages you open. It fills in forms only on sites you have '
        'approved, shows you every value before anything is submitted, and never submits on its '
        'own. It never enters Social Security numbers, account numbers or payment details. '
        'Information you submit to a website goes to that website under its own terms; Motormind AI '
        'is not responsible for how a third-party site handles it.',
  );

  static const List<Disclosure> all = [
    notAdvice,
    notLenderOrDealer,
    noCompensation,
    estimatesOnly,
    illustrativeRates,
    dataStaysOnDevice,
    browserActions,
  ];

  /// Sum of versions; stored on acknowledgement so any change re-prompts.
  static int get gateVersion => all.fold(0, (sum, d) => sum + d.version);

  static String get gateSummary => all.map((d) => d.short).join(' ');

  static Disclosure byKey(String key) => all.firstWhere(
        (d) => d.key == key,
        orElse: () => throw ArgumentError.value(key, 'key', 'unknown disclosure'),
      );
}
