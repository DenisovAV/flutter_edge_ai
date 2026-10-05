import 'package:vehicle_finance/vehicle_finance.dart';

import 'tool_spec.dart';

/// One executed tool call: what the model asked, what the code answered.
///
/// The [id] is what `present` refers to, and [result] is what the narration
/// guard trusts. [error] is set instead of [result] when arguments were bad;
/// the model is shown the error text and asked to correct the call.
class ToolResult {
  const ToolResult({
    required this.id,
    required this.tool,
    required this.args,
    this.result,
    this.error,
  });

  final String id;
  final String tool;
  final Map<String, Object?> args;
  final Map<String, Object?>? result;
  final String? error;

  bool get isError => error != null;

  /// What goes back to the model: the outputs, rounded, plus the inputs it
  /// may need to repeat, without assumption prose. The full result (with
  /// assumptions) goes to the UI, never through the model (ADR 0002). Context
  /// is scarce on a phone, so this is deliberately small.
  Map<String, Object?> toModelJson() {
    if (error != null) return {'result_id': id, 'error': error};
    final r = result ?? const {};
    Object? compact(Object? v) {
      if (v is double) {
        return v == v.roundToDouble() ? v.round() : double.parse(v.toStringAsFixed(2));
      }
      if (v is Map) return {for (final e in v.entries) e.key.toString(): compact(e.value)};
      if (v is List) return [for (final x in v) compact(x)];
      return v;
    }

    if (!r.containsKey('outputs') && !r.containsKey('inputs')) {
      // Not a CalcResult (search, page read): pass it through, compacted.
      return {'result_id': id, ...(compact(r) as Map).cast<String, Object?>()};
    }
    final outputs = compact(r['outputs']) as Map?;
    final inputs = compact(r['inputs']) as Map?;
    final assumptions = r['assumptions'];
    final inputsNoNulls = inputs == null
        ? null
        : {
            for (final e in inputs.entries)
              if (e.value != null) e.key: e.value,
          };
    return {
      'result_id': id,
      'inputs': ?inputsNoNulls,
      'outputs': ?outputs,
      if (assumptions is List && assumptions.isNotEmpty)
        'assumptions': [for (final a in assumptions.cast<Map>()) '${a['key']}=${a['value']}'],
    };
  }
}

/// Turns finance tool arguments into `vehicle_finance` calls.
///
/// Everything numeric the user will see originates here. The handlers are
/// deliberately boring: parse, validate, call, serialize.
class FinanceToolHandlers {
  FinanceToolHandlers({AprTable? aprTable, String Function()? nextId})
    : aprTable = aprTable ?? defaultAprTable,
      _nextId = nextId ?? _counterId;

  final AprTable aprTable;
  final String Function() _nextId;

  static int _counter = 0;
  static String _counterId() => 'r${++_counter}';

  static const Set<String> handled = {
    AdvisorTools.estimatePayment,
    AdvisorTools.maxAffordablePrice,
    AdvisorTools.tradeEquity,
    AdvisorTools.estimateLease,
    AdvisorTools.assessAffordability,
    AdvisorTools.ownershipCost,
  };

  bool handles(String tool) => handled.contains(tool);

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
    final band = _band(a['credit_band']);
    final isNew = _bool(a['is_new'], false);
    final apr = _optNum(a['apr']) ?? aprTable.aprFor(band, isNew: isNew);
    final aprAssumption = a['apr'] != null
        ? _userAssumption(
            'apr.user',
            'APR as given by the user.',
            '${(apr * 100).toStringAsFixed(2)}%',
          )
        : aprTable.assumptionFor(band, isNew: isNew);
    final tradeValue = _optNum(a['trade_value']);
    final tradePayoff = _optNum(a['trade_payoff']);
    final trade = tradeValue != null
        ? tradeEquity(
            estimatedValue: tradeValue,
            payoff: tradePayoff ?? 0,
            valueAssumption: _userAssumption(
              'trade.value',
              'Trade-in value as given by the user or a page they opened.',
              tradeValue.toStringAsFixed(0),
            ),
          )
        : null;
    final deal = DealInputs(
      price: _num(a['price'], 'price'),
      apr: apr,
      termMonths: _int(a['term_months'], 'term_months'),
      salesTaxRate: _optNum(a['sales_tax_rate']) ?? 0,
      fees: _optNum(a['fees']) ?? 0,
      downPayment: _optNum(a['down_payment']) ?? 0,
      trade: trade,
      rollNegativeEquity: _bool(a['roll_negative_equity'], true),
    );
    return estimateDeal(deal, aprAssumption: aprAssumption).toJson();
  }

  Map<String, Object?> _maxAffordablePrice(Map<String, Object?> a) {
    final band = _band(a['credit_band']);
    final isNew = _bool(a['is_new'], false);
    final apr = _optNum(a['apr']) ?? aprTable.aprFor(band, isNew: isNew);
    final payment = _num(a['payment_ceiling'], 'payment_ceiling');
    final term = _int(a['term_months'], 'term_months');
    final principal = maxPriceForPayment(payment: payment, apr: apr, termMonths: term);
    return {
      'inputs': {
        'payment_ceiling': payment,
        'term_months': term,
        'apr': apr,
        'credit_band': band.name,
      },
      'outputs': {'max_amount_financed': principal},
      'assumptions': [
        (a['apr'] != null
                ? _userAssumption(
                    'apr.user',
                    'APR as given by the user.',
                    '${(apr * 100).toStringAsFixed(2)}%',
                  )
                : aprTable.assumptionFor(band, isNew: isNew))
            .toJson(),
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
    final value = _num(a['estimated_value'], 'estimated_value');
    return tradeEquity(
      estimatedValue: value,
      payoff: _num(a['payoff'], 'payoff'),
      valueAssumption: _userAssumption(
        'trade.value',
        'Trade-in value as given by the user or a page they opened.',
        value.toStringAsFixed(0),
      ),
    ).toJson();
  }

  Map<String, Object?> _estimateLease(Map<String, Object?> a) {
    final mf = _num(a['money_factor'], 'money_factor');
    return estimateLease(
      LeaseInputs(
        capitalizedCost: _num(a['capitalized_cost'], 'capitalized_cost'),
        residualValue: _num(a['residual_value'], 'residual_value'),
        moneyFactor: mf,
        termMonths: _int(a['term_months'], 'term_months'),
        capReduction: _optNum(a['cap_reduction']) ?? 0,
        salesTaxRate: _optNum(a['sales_tax_rate']) ?? 0,
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
      monthlyGrossIncome: _num(a['monthly_gross_income'], 'monthly_gross_income'),
      monthlyDebtPayments: _optNum(a['monthly_debt_payments']) ?? 0,
      proposedPayment: _num(a['proposed_payment'], 'proposed_payment'),
      termMonths: _int(a['term_months'], 'term_months'),
      paymentCeiling: _optNum(a['payment_ceiling']),
    ),
  ).toJson();

  Map<String, Object?> _ownershipCost(Map<String, Object?> a) => estimateOwnership(
    OwnershipInputs(
      vehicleClass: VehicleClass.parse(_str(a['vehicle_class'], 'vehicle_class')),
      purchasePrice: _num(a['purchase_price'], 'purchase_price'),
      milesPerYear: _int(a['miles_per_year'], 'miles_per_year'),
      fuelType: FuelType.values.byName(_str(a['fuel_type'], 'fuel_type')),
      efficiency: _num(a['efficiency'], 'efficiency'),
      years: _optInt(a['years']) ?? 5,
      vehicleAgeYears: _optInt(a['vehicle_age_years']) ?? 0,
      insuranceBand: a['insurance_band'] == null
          ? InsuranceBand.average
          : InsuranceBand.values.byName(a['insurance_band'] as String),
      salesTaxRate: _optNum(a['sales_tax_rate']) ?? 0,
    ),
  ).toJson();

  // --- argument parsing ---------------------------------------------------

  static CreditBand _band(Object? v) {
    if (v == null) throw ArgumentError('credit_band is required');
    return CreditBand.parse(v.toString());
  }

  static double _num(Object? v, String name) {
    final n = _optNum(v);
    if (n == null) throw ArgumentError('$name is required and must be a number');
    return n;
  }

  static double? _optNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      final cleaned = v.replaceAll(RegExp(r'[\$,%\s]'), '');
      return double.tryParse(cleaned);
    }
    return null;
  }

  static int _int(Object? v, String name) {
    final n = _optInt(v);
    if (n == null) throw ArgumentError('$name is required and must be a whole number');
    return n;
  }

  static int? _optInt(Object? v) {
    final n = _optNum(v);
    return n?.round();
  }

  static bool _bool(Object? v, bool fallback) {
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return fallback;
  }

  static String _str(Object? v, String name) {
    if (v == null) throw ArgumentError('$name is required');
    return v.toString();
  }

  static Assumption _userAssumption(String key, String description, String value) => Assumption(
    key: key,
    description: description,
    value: value,
    source: 'user',
    asOf: '2026-10-04',
    illustrative: false,
  );
}
