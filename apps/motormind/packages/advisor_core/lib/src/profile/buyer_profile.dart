import 'package:vehicle_finance/vehicle_finance.dart';

enum ItemKind { need, want, unlabeled }

/// How the user is shopping right now. Not a tone setting: the advisor infers
/// it from what the user says and updates it when intent shifts ("just
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

/// Something the user said they are looking for. The user labels it; the
/// advisor only proposes a label and asks.
class ProfileItem {
  const ProfileItem({required this.label, this.kind = ItemKind.unlabeled, this.source = 'user'});

  final String label;
  final ItemKind kind;
  final String source;

  ProfileItem copyWith({ItemKind? kind}) =>
      ProfileItem(label: label, kind: kind ?? this.kind, source: source);

  Map<String, Object?> toJson() => {'label': label, 'kind': kind.name, 'source': source};

  factory ProfileItem.fromJson(Map<String, Object?> json) => ProfileItem(
    label: json['label'] as String,
    kind: ItemKind.values.byName(json['kind'] as String? ?? 'unlabeled'),
    source: json['source'] as String? ?? 'user',
  );
}

/// What the advisor knows about the buyer. Everything is optional; the
/// advisor asks for what it needs when it needs it.
class BuyerProfile {
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
    this.preferNew,
  });

  final List<ProfileItem> items;
  final double? paymentCeiling;
  final double? downPayment;
  final CreditBand? creditBand;
  final double? monthlyGrossIncome;
  final double? monthlyDebtPayments;
  final double? tradeValue;
  final double? tradePayoff;
  final ShoppingMode? mode;
  final bool? preferNew;

  List<ProfileItem> get needs => items.where((i) => i.kind == ItemKind.need).toList();
  List<ProfileItem> get wants => items.where((i) => i.kind == ItemKind.want).toList();
  List<ProfileItem> get unlabeled => items.where((i) => i.kind == ItemKind.unlabeled).toList();

  bool get hasTrade => tradeValue != null || tradePayoff != null;

  /// Applies the arguments of an `update_profile` tool call. Items with the
  /// same label are replaced, so the user can relabel a want as a need.
  BuyerProfile applyUpdate(Map<String, Object?> args) {
    final newItems = <ProfileItem>[...items];
    final rawItems = args['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final label = raw['label']?.toString().trim();
        if (label == null || label.isEmpty) continue;
        final kindName = raw['kind']?.toString() ?? 'unlabeled';
        final kind =
            ItemKind.values.where((k) => k.name == kindName).firstOrNull ?? ItemKind.unlabeled;
        newItems.removeWhere((i) => i.label.toLowerCase() == label.toLowerCase());
        newItems.add(
          ProfileItem(label: label, kind: kind, source: raw['source']?.toString() ?? 'user'),
        );
      }
    }
    CreditBand? band = creditBand;
    if (args['credit_band'] != null) {
      band = CreditBand.parse(args['credit_band'].toString());
    }
    if (args['credit_score'] != null) {
      final score = _toNum(args['credit_score']);
      if (score != null) {
        band = creditBandForScore(score.round());
      }
    }
    ShoppingMode? newMode = mode;
    if (args['shopping_mode'] != null) {
      newMode =
          ShoppingMode.values
              .where((m) => m.name == args['shopping_mode'].toString())
              .firstOrNull ??
          mode;
    }
    return BuyerProfile(
      items: newItems,
      paymentCeiling: _toNum(args['payment_ceiling']) ?? paymentCeiling,
      downPayment: _toNum(args['down_payment']) ?? downPayment,
      creditBand: band,
      monthlyGrossIncome: _toNum(args['monthly_gross_income']) ?? monthlyGrossIncome,
      monthlyDebtPayments: _toNum(args['monthly_debt_payments']) ?? monthlyDebtPayments,
      tradeValue: _toNum(args['trade_value']) ?? tradeValue,
      tradePayoff: _toNum(args['trade_payoff']) ?? tradePayoff,
      mode: newMode,
      preferNew: args['prefer_new'] is bool ? args['prefer_new'] as bool : preferNew,
    );
  }

  /// Short summary for the system prompt. No numbers are invented; absent
  /// fields are simply absent.
  String toPromptSummary() {
    final parts = <String>[];
    if (mode != null) {
      parts.add('shopping mode: ${mode!.name}');
    }
    if (paymentCeiling != null) {
      parts.add('payment ceiling: \$${paymentCeiling!.toStringAsFixed(0)}/mo');
    }
    if (downPayment != null) {
      parts.add('down payment: \$${downPayment!.toStringAsFixed(0)}');
    }
    if (creditBand != null) parts.add('credit band: ${creditBand!.name}');
    if (monthlyGrossIncome != null) {
      parts.add('gross income: \$${monthlyGrossIncome!.toStringAsFixed(0)}/mo');
    }
    if (hasTrade) {
      parts.add(
        'trade-in value: ${tradeValue?.toStringAsFixed(0) ?? 'unknown'}, payoff: ${tradePayoff?.toStringAsFixed(0) ?? 'unknown'}',
      );
    }
    if (needs.isNotEmpty) {
      parts.add('needs: ${needs.map((i) => i.label).join(', ')}');
    }
    if (wants.isNotEmpty) parts.add('wants: ${wants.map((i) => i.label).join(', ')}');
    if (unlabeled.isNotEmpty) {
      parts.add('mentioned (unlabeled): ${unlabeled.map((i) => i.label).join(', ')}');
    }
    return parts.isEmpty ? 'nothing known yet' : parts.join('; ');
  }

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
    'preferNew': preferNew,
  };

  factory BuyerProfile.fromJson(Map<String, Object?> json) => BuyerProfile(
    items: [
      for (final i in (json['items'] as List? ?? const []))
        ProfileItem.fromJson((i as Map).cast<String, Object?>()),
    ],
    paymentCeiling: _toNum(json['paymentCeiling']),
    downPayment: _toNum(json['downPayment']),
    creditBand: json['creditBand'] == null ? null : CreditBand.parse(json['creditBand'] as String),
    monthlyGrossIncome: _toNum(json['monthlyGrossIncome']),
    monthlyDebtPayments: _toNum(json['monthlyDebtPayments']),
    tradeValue: _toNum(json['tradeValue']),
    tradePayoff: _toNum(json['tradePayoff']),
    mode: json['mode'] == null ? null : ShoppingMode.values.byName(json['mode'] as String),
    preferNew: json['preferNew'] as bool?,
  );

  static double? _toNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.replaceAll(RegExp(r'[\$,\s]'), ''));
    return null;
  }
}
