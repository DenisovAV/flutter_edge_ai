import 'package:vehicle_finance/vehicle_finance.dart';

import '../parse.dart';
import 'tool_spec.dart';

/// One executed tool call: what the model asked, what the code answered.
///
/// The [id] is what `present` refers to, and [result] is what the narration
/// guard trusts. [error] is set instead of [result] when arguments were bad;
/// the model is shown the error text and asked to correct the call.
class ToolResult {
  /// Creates a result; set [result] on success or [error] on refusal.
  const ToolResult({
    required this.id,
    required this.tool,
    required this.args,
    this.result,
    this.error,
  });

  /// Identifier the model uses in `present(result_id)`: `r` plus a counter
  /// drawn from one sequence for every tool in the conversation.
  final String id;

  /// Name of the tool that was called.
  final String tool;

  /// Arguments as the model supplied them.
  final Map<String, Object?> args;

  /// The tool's full output, assumptions included, for the UI; null on error.
  final Map<String, Object?>? result;

  /// Why the call was refused, in words the model is shown; null on success.
  final String? error;

  /// True when the call was refused and [result] is null.
  bool get isError => error != null;

  /// What goes back to the model: the outputs, rounded, plus the inputs it
  /// may need to repeat, without assumption prose. The full result (with
  /// assumptions) goes to the UI, never through the model (ADR 0002). Context
  /// is scarce on a phone, so this is deliberately small.
  Map<String, Object?> toModelJson() {
    if (error != null) return {'result_id': id, 'error': error};
    final r = result ?? const {};
    if (!r.containsKey('outputs') && !r.containsKey('inputs')) {
      // Not a CalcResult (search, page read): pass it through, compacted.
      return {'result_id': id, ..._compactMap(r)};
    }
    final outputs = r['outputs'];
    final inputs = r['inputs'];
    final assumptions = r['assumptions'];
    final inputsNoNulls = inputs is! Map
        ? null
        : {
            for (final e in _compactMap(inputs).entries)
              if (e.value != null) e.key: e.value,
          };
    return {
      'result_id': id,
      'inputs': ?inputsNoNulls,
      if (outputs is Map) 'outputs': _compactMap(outputs),
      if (assumptions is List && assumptions.isNotEmpty)
        'assumptions': [for (final a in assumptions.cast<Map>()) '${a['key']}=${a['value']}'],
    };
  }

  static Map<String, Object?> _compactMap(Map<Object?, Object?> m) => {
    for (final e in m.entries) e.key.toString(): _compactValue(e.value),
  };

  /// Whole-dollar doubles (22700.0) go out as ints (22700) and the rest to
  /// two decimals: a `.0` costs a token on every number the model reads.
  static Object? _compactValue(Object? v) {
    if (v is double) {
      return v == v.roundToDouble() ? v.round() : double.parse(v.toStringAsFixed(2));
    }
    if (v is Map) return _compactMap(v);
    if (v is List) return [for (final x in v) _compactValue(x)];
    return v;
  }
}

/// Turns finance tool arguments into `vehicle_finance` calls.
///
/// Everything numeric the user will see originates here. The handlers are
/// deliberately boring: parse, validate, call, serialize.
class FinanceToolHandlers {
  /// Creates handlers over [aprTable] (the package default when omitted).
  /// [nextId] replaces the per-instance result-id counter and [now] the
  /// clock that dates user-supplied assumptions; tests inject both.
  FinanceToolHandlers({AprTable? aprTable, String Function()? nextId, DateTime Function()? now})
    : aprTable = aprTable ?? defaultAprTable,
      _now = now ?? DateTime.now {
    _nextId = nextId ?? () => 'r${++_counter}';
  }

  /// The rate table consulted when the person gave no APR.
  final AprTable aprTable;

  final DateTime Function() _now;
  late final String Function() _nextId;
  int _counter = 0;

  static const Set<String> _handled = {
    AdvisorTools.estimatePayment,
    AdvisorTools.maxAffordablePrice,
    AdvisorTools.tradeEquity,
    AdvisorTools.estimateLease,
    AdvisorTools.assessAffordability,
    AdvisorTools.ownershipCost,
  };

  /// True when [tool] is one of the finance tools these handlers execute.
  bool handles(String tool) => _handled.contains(tool);

  /// Draws the next result id. The pipeline uses the same sequence for the
  /// tools it runs itself, so every id in a conversation is unique.
  String nextId() => _nextId();

  /// Executes [tool] with [args]. Bad or missing arguments produce an error
  /// result rather than an exception, so the model can correct the call.
  ToolResult call(String tool, Map<String, Object?> args) {
    final id = _nextId();
    try {
      final result = switch (tool) {
        AdvisorTools.estimatePayment => _estimatePayment(args),
        AdvisorTools.maxAffordablePrice => _maxAffordablePrice(args),
        AdvisorTools.tradeEquity => _tradeEquity(args),
        AdvisorTools.estimateLease => _estimateLease(args),
        AdvisorTools.assessAffordability => _assessAffordability(args),
        AdvisorTools.ownershipCost => _ownershipCost(args),
        _ => throw ArgumentError.value(tool, 'tool', 'not a finance tool'),
      };
      return ToolResult(id: id, tool: tool, args: args, result: result);
    } on ArgumentError catch (e) {
      return ToolResult(id: id, tool: tool, args: args, error: 'Invalid argument: ${e.message}');
    } on FormatException catch (e) {
      return ToolResult(id: id, tool: tool, args: args, error: 'Invalid argument: ${e.message}');
    }
  }

  // --- handlers -----------------------------------------------------------

  Map<String, Object?> _estimatePayment(Map<String, Object?> a) {
    final band = _requireEnum(CreditBand.values, a['credit_band'], 'credit_band');
    final isNew = _boolOr(a['is_new'], false);
    final apr = _optionalNumber(a['apr']) ?? aprTable.aprFor(band, isNew: isNew);
    final tradeValue = _optionalNumber(a['trade_value']);
    final tradePayoff = _optionalNumber(a['trade_payoff']);
    final trade = tradeValue != null
        ? tradeEquity(
            estimatedValue: tradeValue,
            payoff: tradePayoff ?? 0,
            valueAssumption: _tradeValueAssumption(tradeValue),
          )
        : null;
    final deal = DealInputs(
      price: _requireNumber(a['price'], 'price'),
      apr: apr,
      termMonths: _requireInt(a['term_months'], 'term_months'),
      salesTaxRate: _optionalNumber(a['sales_tax_rate']) ?? 0,
      fees: _optionalNumber(a['fees']) ?? 0,
      downPayment: _optionalNumber(a['down_payment']) ?? 0,
      trade: trade,
      rollNegativeEquity: _boolOr(a['roll_negative_equity'], true),
    );
    return estimateDeal(
      deal,
      aprAssumption: _aprAssumptionFor(a['apr'], apr, band, isNew: isNew),
    ).toJson();
  }

  Map<String, Object?> _maxAffordablePrice(Map<String, Object?> a) {
    final band = _requireEnum(CreditBand.values, a['credit_band'], 'credit_band');
    final isNew = _boolOr(a['is_new'], false);
    final apr = _optionalNumber(a['apr']) ?? aprTable.aprFor(band, isNew: isNew);
    final payment = _requireNumber(a['payment_ceiling'], 'payment_ceiling');
    final term = _requireInt(a['term_months'], 'term_months');
    final principal = maxPrincipal(payment: payment, apr: apr, termMonths: term);
    return {
      'inputs': {
        'payment_ceiling': payment,
        'term_months': term,
        'apr': apr,
        'credit_band': band.name,
      },
      'outputs': {'max_amount_financed': principal},
      'assumptions': [
        _aprAssumptionFor(a['apr'], apr, band, isNew: isNew).toJson(),
        // A definition, not a measurement: the date is when the wording was
        // last checked, so it stays fixed rather than following the clock.
        const Assumption(
          key: 'max_price.scope',
          description:
              'This is the amount that can be financed; tax, fees, down payment and trade equity change the sticker price it supports.',
          value: 'amount financed only',
          source: 'definition',
          asOf: '2026-10-04',
          illustrative: false,
        ).toJson(),
      ],
    };
  }

  Map<String, Object?> _tradeEquity(Map<String, Object?> a) {
    final value = _requireNumber(a['estimated_value'], 'estimated_value');
    return tradeEquity(
      estimatedValue: value,
      payoff: _requireNumber(a['payoff'], 'payoff'),
      valueAssumption: _tradeValueAssumption(value),
    ).toJson();
  }

  Map<String, Object?> _estimateLease(Map<String, Object?> a) {
    final mf = _requireNumber(a['money_factor'], 'money_factor');
    return estimateLease(
      LeaseInputs(
        capitalizedCost: _requireNumber(a['capitalized_cost'], 'capitalized_cost'),
        residualValue: _requireNumber(a['residual_value'], 'residual_value'),
        moneyFactor: mf,
        termMonths: _requireInt(a['term_months'], 'term_months'),
        capReduction: _optionalNumber(a['cap_reduction']) ?? 0,
        salesTaxRate: _optionalNumber(a['sales_tax_rate']) ?? 0,
      ),
      moneyFactorAssumption: _userAssumption(
        'lease.money_factor',
        'Money factor from the lease offer.',
        mf.toStringAsFixed(5),
      ),
    ).toJson();
  }

  Map<String, Object?> _assessAffordability(Map<String, Object?> a) => assessAffordability(
    AffordabilityInputs(
      monthlyGrossIncome: _requireNumber(a['monthly_gross_income'], 'monthly_gross_income'),
      monthlyDebtPayments: _optionalNumber(a['monthly_debt_payments']) ?? 0,
      proposedPayment: _requireNumber(a['proposed_payment'], 'proposed_payment'),
      termMonths: _requireInt(a['term_months'], 'term_months'),
      paymentCeiling: _optionalNumber(a['payment_ceiling']),
    ),
  ).toJson();

  Map<String, Object?> _ownershipCost(Map<String, Object?> a) => estimateOwnership(
    OwnershipInputs(
      vehicleClass: _requireEnum(VehicleClass.values, a['vehicle_class'], 'vehicle_class'),
      purchasePrice: _requireNumber(a['purchase_price'], 'purchase_price'),
      milesPerYear: _requireInt(a['miles_per_year'], 'miles_per_year'),
      fuelType: _requireEnum(FuelType.values, a['fuel_type'], 'fuel_type'),
      efficiency: _requireNumber(a['efficiency'], 'efficiency'),
      years: _optionalInt(a['years']) ?? 5,
      vehicleAgeYears: _optionalInt(a['vehicle_age_years']) ?? 0,
      insuranceBand: a['insurance_band'] == null
          ? InsuranceBand.average
          : _requireEnum(InsuranceBand.values, a['insurance_band'], 'insurance_band'),
      salesTaxRate: _optionalNumber(a['sales_tax_rate']) ?? 0,
    ),
  ).toJson();

  // --- assumptions --------------------------------------------------------

  /// The APR assumption for a deal: attributed to the person when they gave
  /// [rawApr], otherwise the dated table entry for [band].
  Assumption _aprAssumptionFor(
    Object? rawApr,
    double apr,
    CreditBand band, {
    required bool isNew,
  }) => rawApr != null
      ? _userAssumption(
          'apr.user',
          'APR as given by the user.',
          '${(apr * 100).toStringAsFixed(2)}%',
        )
      : aprTable.assumptionFor(band, isNew: isNew);

  Assumption _tradeValueAssumption(double value) => _userAssumption(
    'trade.value',
    'Trade-in value as given by the user or a page they opened.',
    value.toStringAsFixed(0),
  );

  /// An assumption sourced from the person, dated today so the card can say
  /// when the figure was given.
  Assumption _userAssumption(String key, String description, String value) => Assumption(
    key: key,
    description: description,
    value: value,
    source: 'user',
    asOf: _isoDate(_now()),
    illustrative: false,
  );

  static String _isoDate(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  // --- argument parsing ---------------------------------------------------
  // Every helper tolerates the model's habits (numbers as strings, "$18,500",
  // "6%") and reports a bad or missing value as an ArgumentError, which
  // [call] turns into an error result. Nothing here throws a TypeError.

  static double _requireNumber(Object? v, String name) {
    final n = _optionalNumber(v);
    if (n == null) throw ArgumentError('$name is required and must be a number');
    return n;
  }

  static double? _optionalNumber(Object? v) => parseTolerantNumber(v);

  static int _requireInt(Object? v, String name) {
    final n = _optionalInt(v);
    if (n == null) throw ArgumentError('$name is required and must be a whole number');
    return n;
  }

  static int? _optionalInt(Object? v) => _optionalNumber(v)?.round();

  static bool _boolOr(Object? v, bool fallback) {
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return fallback;
  }

  static String _requireString(Object? v, String name) {
    if (v == null) throw ArgumentError('$name is required');
    return v.toString();
  }

  /// Looks [v] up in [values] by name, ignoring case and whitespace, so a
  /// number or a capitalized name never escapes as a TypeError.
  static T _requireEnum<T extends Enum>(List<T> values, Object? v, String name) {
    final text = _requireString(v, name).toLowerCase().trim();
    for (final value in values) {
      if (value.name == text) return value;
    }
    throw ArgumentError('$name must be one of ${values.map((e) => e.name).join(', ')}');
  }
}
