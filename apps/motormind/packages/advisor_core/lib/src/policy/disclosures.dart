/// One disclosure, versioned so a change re-prompts the gate.
class Disclosure {
  /// Creates a disclosure; [version] is bumped whenever [short] or [long]
  /// changes.
  const Disclosure({
    required this.key,
    required this.version,
    required this.short,
    required this.long,
  });

  /// Stable identifier used for lookup ([Disclosures.byKey]) and storage.
  final String key;

  /// Wording version; summed into [Disclosures.gateVersion], so a change
  /// re-prompts the gate.
  final int version;

  /// One sentence, shown inline and in the gate summary.
  final String short;

  /// The fuller explanation, shown on the disclosures screen and the web page.
  final String long;
}

/// The single source of disclosure wording. The gate screen, the settings
/// screen, result cards and the hosted web page all read from here.
abstract final class Disclosures {
  /// The app shows estimates, not advice.
  static const notAdvice = Disclosure(
    key: 'not_advice',
    version: 1,
    short: 'This is not financial advice.',
    long:
        'Motormind AI is an information tool. It shows estimates computed from the numbers you '
        'provide and from stated assumptions. It does not know your full financial situation and '
        'is not a substitute for a licensed advisor, a lender\'s disclosure, or your own judgment.',
  );

  /// The app neither lends nor sells.
  static const notLenderOrDealer = Disclosure(
    key: 'not_lender_or_dealer',
    version: 1,
    short: 'We are not a lender or a dealer.',
    long:
        'Motormind AI does not offer credit, sell or lease vehicles, take applications, or pass '
        'your information to any lender or dealer. Nothing here is an offer of credit.',
  );

  /// No one pays the app for a purchase, lease or loan.
  static const noCompensation = Disclosure(
    key: 'no_compensation',
    version: 1,
    short: 'We receive no compensation from any purchase, lease or loan.',
    long:
        'No one pays Motormind AI when you buy, lease or finance a vehicle, and no vehicle or '
        'lender is ranked higher because of a business relationship. Any advertising in the app is '
        'labeled as such and does not affect results.',
  );

  /// Every figure is an estimate.
  static const estimatesOnly = Disclosure(
    key: 'estimates_only',
    version: 1,
    short: 'All figures are estimates.',
    long:
        'Payments, costs and values are computed from your inputs and from assumptions the app '
        'states next to each result. Actual figures depend on the lender, the vehicle, taxes and fees '
        'in your area, and your full credit file.',
  );

  /// Rates come from a dated table, not from a lender.
  static const illustrativeRates = Disclosure(
    key: 'illustrative_rates',
    version: 1,
    short: 'Interest rates shown are illustrative, not quotes.',
    long:
        'Rates by credit band come from a dated table that is shown beside every rate. They are '
        'typical ranges, not an offer, and you can replace them with a rate you were quoted.',
  );

  /// Financial information never leaves the phone.
  static const dataStaysOnDevice = Disclosure(
    key: 'data_on_device',
    version: 1,
    short: 'Your financial information stays on your device.',
    long:
        'The assistant runs on your phone. Your income, credit band, trade-in and payment '
        'information are stored only on this device and are never uploaded. Anonymous usage '
        'statistics, if enabled, contain no personal or financial information.',
  );

  /// Nothing is submitted to a website without the person's approval.
  static const browserActions = Disclosure(
    key: 'browser_actions',
    version: 1,
    short: 'Web actions require your approval, every time.',
    long:
        'The assistant can read web pages you open. It fills in forms only on sites you have '
        'approved, shows you every value before anything is submitted, and never submits on its '
        'own. It never enters Social Security numbers, account numbers or payment details. '
        'Information you submit to a website goes to that website under its own terms; Motormind AI '
        'is not responsible for how a third-party site handles it.',
  );

  /// Every disclosure, in the order the gate and the settings screen show
  /// them.
  static const List<Disclosure> all = [
    notAdvice,
    notLenderOrDealer,
    noCompensation,
    estimatesOnly,
    illustrativeRates,
    dataStaysOnDevice,
    browserActions,
  ];

  /// Sum of every [Disclosure.version]; stored on acknowledgement so any
  /// change re-prompts the gate. A sum is enough because disclosures are
  /// never removed, only reworded with a bumped version: the total can only
  /// grow, so a stored value below the current one always means something
  /// changed since it was accepted.
  static int get gateVersion => all.fold(0, (sum, d) => sum + d.version);

  /// Looks up a disclosure by [Disclosure.key]; throws [ArgumentError] when
  /// there is none.
  static Disclosure byKey(String key) => all.firstWhere(
    (d) => d.key == key,
    orElse: () => throw ArgumentError.value(key, 'key', 'unknown disclosure'),
  );
}
