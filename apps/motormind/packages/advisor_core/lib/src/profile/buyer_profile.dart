import 'package:vehicle_finance/vehicle_finance.dart';

import '../parse.dart';

/// How the person labeled something they are looking for.
enum ItemKind {
  /// A requirement; the person said they need it.
  need,

  /// A preference; the person said they want it.
  want,

  /// Mentioned, but the person has not said which.
  unlabeled,
}

/// How the person is shopping right now. Not a tone setting: the model infers
/// it from what the person says and updates it when intent shifts ("just
/// looking" → "ok, maybe I do want this"). Tone follows mode.
enum ShoppingMode {
  /// Just looking; no commitment, light touch.
  browsing,

  /// Dream car, for fun; supportive, playful, still honest about numbers.
  dreaming,

  /// Practical options; sympathetic, concrete, never judgmental.
  practical,

  /// Buying now; precise, detailed budgeting, serious.
  buying,
}

/// Looks [raw] up in [values] by name, ignoring case and whitespace; null
/// for null, for an unknown name and for anything that is not a name. Tool
/// arguments and stored JSON both go through here so a stray value never
/// throws out of a profile update or a restore.
T? _byName<T extends Enum>(List<T> values, Object? raw) {
  if (raw == null) return null;
  final name = raw.toString().toLowerCase().trim();
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// Something the person said they are looking for. The person labels it;
/// Motormind only proposes a label and asks.
class ProfileItem {
  /// Creates an item; [kind] defaults to unlabeled and [source] to the person.
  const ProfileItem({required this.label, this.kind = ItemKind.unlabeled, this.source = 'user'});

  /// The item in the person's words ("third row", "good mileage").
  final String label;

  /// Whether the person called it a need, a want, or neither.
  final ItemKind kind;

  /// Who added the item: `user` unless a tool argument says otherwise.
  final String source;

  /// Serializes for on-device storage; see [ProfileItem.fromJson].
  Map<String, Object?> toJson() => {'label': label, 'kind': kind.name, 'source': source};

  /// Restores an item written by [toJson]; missing or unknown fields take
  /// their defaults.
  factory ProfileItem.fromJson(Map<String, Object?> json) => ProfileItem(
    label: json['label']?.toString() ?? '',
    kind: _byName(ItemKind.values, json['kind']) ?? ItemKind.unlabeled,
    source: json['source']?.toString() ?? 'user',
  );
}

/// What Motormind knows about the buyer. Everything is optional; the model
/// asks for what it needs when it needs it.
class BuyerProfile {
  /// Creates a profile; every field starts unknown.
  const BuyerProfile({
    this.items = const [],
    this.paymentCeiling,
    this.downPayment,
    this.creditBand,
    this.monthlyGrossIncome,
    this.monthlyDebtPayments,
    this.tradeValue,
    this.tradePayoff,
    this.mode,
  });

  /// Everything the person said they are looking for, labeled or not.
  final List<ProfileItem> items;

  /// The most the person will pay per month, in dollars.
  final double? paymentCeiling;

  /// Cash the person will put down, in dollars.
  final double? downPayment;

  /// The person's credit band, stated directly or derived from a score.
  final CreditBand? creditBand;

  /// Gross monthly income in dollars, used only by affordability checks.
  final double? monthlyGrossIncome;

  /// Existing monthly debt payments in dollars.
  final double? monthlyDebtPayments;

  /// Estimated value of the current vehicle, in dollars.
  final double? tradeValue;

  /// Remaining loan balance on the current vehicle, in dollars.
  final double? tradePayoff;

  /// How the person is shopping; null until the model infers it.
  final ShoppingMode? mode;

  /// Items the person labeled as needs.
  List<ProfileItem> get needs => items.where((i) => i.kind == ItemKind.need).toList();

  /// Items the person labeled as wants.
  List<ProfileItem> get wants => items.where((i) => i.kind == ItemKind.want).toList();

  /// Items the person mentioned without labeling.
  List<ProfileItem> get unlabeled => items.where((i) => i.kind == ItemKind.unlabeled).toList();

  /// True when anything is known about a trade-in.
  bool get hasTrade => tradeValue != null || tradePayoff != null;

  /// Applies the arguments of an `update_profile` tool call. Items with the
  /// same label are replaced, so the person can relabel a want as a need.
  /// A `credit_score` argument overrides `credit_band`; an unknown enum
  /// value (a band of "platinum", a mode of "serious") leaves the current
  /// value in place rather than failing the whole update.
  BuyerProfile applyUpdate(Map<String, Object?> args) {
    final newItems = <ProfileItem>[...items];
    final rawItems = args['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final label = raw['label']?.toString().trim();
        if (label == null || label.isEmpty) continue;
        final kind = _byName(ItemKind.values, raw['kind']) ?? ItemKind.unlabeled;
        newItems.removeWhere((i) => i.label.toLowerCase() == label.toLowerCase());
        newItems.add(
          ProfileItem(label: label, kind: kind, source: raw['source']?.toString() ?? 'user'),
        );
      }
    }
    var band = _byName(CreditBand.values, args['credit_band']) ?? creditBand;
    final score = parseTolerantNumber(args['credit_score']);
    if (score != null) band = creditBandForScore(score.round());
    return BuyerProfile(
      items: newItems,
      paymentCeiling: parseTolerantNumber(args['payment_ceiling']) ?? paymentCeiling,
      downPayment: parseTolerantNumber(args['down_payment']) ?? downPayment,
      creditBand: band,
      monthlyGrossIncome: parseTolerantNumber(args['monthly_gross_income']) ?? monthlyGrossIncome,
      monthlyDebtPayments:
          parseTolerantNumber(args['monthly_debt_payments']) ?? monthlyDebtPayments,
      tradeValue: parseTolerantNumber(args['trade_value']) ?? tradeValue,
      tradePayoff: parseTolerantNumber(args['trade_payoff']) ?? tradePayoff,
      mode: _byName(ShoppingMode.values, args['shopping_mode']) ?? mode,
    );
  }

  /// Short summary for the system prompt. No numbers are invented; absent
  /// fields are simply absent.
  String toPromptSummary() {
    final parts = <String>[
      if (mode != null) 'shopping mode: ${mode!.name}',
      if (paymentCeiling != null) 'payment ceiling: ${_money(paymentCeiling)}/mo',
      if (downPayment != null) 'down payment: ${_money(downPayment)}',
      if (creditBand != null) 'credit band: ${creditBand!.name}',
      if (monthlyGrossIncome != null) 'gross income: ${_money(monthlyGrossIncome)}/mo',
      if (monthlyDebtPayments != null) 'debt payments: ${_money(monthlyDebtPayments)}/mo',
      if (hasTrade) 'trade-in value: ${_money(tradeValue)}, payoff: ${_money(tradePayoff)}',
      if (needs.isNotEmpty) 'needs: ${needs.map((i) => i.label).join(', ')}',
      if (wants.isNotEmpty) 'wants: ${wants.map((i) => i.label).join(', ')}',
      if (unlabeled.isNotEmpty)
        'mentioned (unlabeled): ${unlabeled.map((i) => i.label).join(', ')}',
    ];
    return parts.isEmpty ? 'nothing known yet' : parts.join('; ');
  }

  /// Whole dollars with a `$`, or `unknown`, so every amount in the summary
  /// reads the same way to the model.
  static String _money(double? amount) =>
      amount == null ? 'unknown' : '\$${amount.toStringAsFixed(0)}';

  /// Serializes for on-device storage; see [BuyerProfile.fromJson].
  Map<String, Object?> toJson() => {
    'items': [for (final i in items) i.toJson()],
    'paymentCeiling': paymentCeiling,
    'downPayment': downPayment,
    'creditBand': creditBand?.name,
    'monthlyGrossIncome': monthlyGrossIncome,
    'monthlyDebtPayments': monthlyDebtPayments,
    'tradeValue': tradeValue,
    'tradePayoff': tradePayoff,
    'mode': mode?.name,
  };

  /// Restores a profile written by [toJson]. Tolerant of what an older build
  /// or a hand-edited file may hold: unknown names become null and items
  /// that are not maps are skipped.
  factory BuyerProfile.fromJson(Map<String, Object?> json) => BuyerProfile(
    items: [
      for (final i in (json['items'] as List? ?? const []))
        if (i is Map) ProfileItem.fromJson(i.cast<String, Object?>()),
    ],
    paymentCeiling: parseTolerantNumber(json['paymentCeiling']),
    downPayment: parseTolerantNumber(json['downPayment']),
    creditBand: _byName(CreditBand.values, json['creditBand']),
    monthlyGrossIncome: parseTolerantNumber(json['monthlyGrossIncome']),
    monthlyDebtPayments: parseTolerantNumber(json['monthlyDebtPayments']),
    tradeValue: parseTolerantNumber(json['tradeValue']),
    tradePayoff: parseTolerantNumber(json['tradePayoff']),
    mode: _byName(ShoppingMode.values, json['mode']),
  );
}
