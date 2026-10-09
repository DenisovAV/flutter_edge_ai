/// A tool the model may call. Mirrors the shape inference SDKs expect
/// (name, description, JSON-schema parameters) without depending on one.
///
/// Every character here is paid on every turn in a 4k context window, so
/// descriptions are terse and say WHEN to call, not what the app does.
class ToolSpec {
  /// Creates a spec; [parameters] is a JSON-schema object.
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    this.changesUi = false,
  });

  /// Name the model calls, in snake_case.
  final String name;

  /// When to call the tool, in as few words as possible.
  final String description;

  /// JSON schema for the arguments, in the shape inference SDKs expect.
  final Map<String, Object?> parameters;

  /// True when the tool's purpose is to change what is on screen rather than
  /// to compute something.
  final bool changesUi;

  /// Serializes to the `{name, description, parameters}` shape SDKs accept.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}

const _bands = ['excellent', 'good', 'fair', 'poor', 'rebuilding'];

/// Body styles the `update_search` tool accepts.
abstract final class SearchQueryBodyStyles {
  /// The accepted values; the tool schema adds `any` to clear the filter.
  static const values = [
    'suv',
    'sedan',
    'coupe',
    'convertible',
    'hatchback',
    'pickup',
    'van',
    'wagon',
  ];
}

const _classes = ['car', 'suv', 'pickup', 'van'];

Map<String, Object?> _num([String? d]) => {'type': 'number', 'description': ?d};
Map<String, Object?> _int([String? d]) => {'type': 'integer', 'description': ?d};
Map<String, Object?> _str([String? d, List<String>? e]) => {
  'type': 'string',
  'description': ?d,
  'enum': ?e,
};
Map<String, Object?> _bool([String? d]) => {'type': 'boolean', 'description': ?d};
Map<String, Object?> _obj(Map<String, Object?> props, [List<String> required = const []]) => {
  'type': 'object',
  'properties': props,
  if (required.isNotEmpty) 'required': required,
};

/// Every tool Motormind offers the model, in the order they are described in
/// the system prompt.
abstract final class AdvisorTools {
  /// Monthly payment and purchase breakdown for a vehicle.
  static const String estimatePayment = 'estimate_payment';

  /// Highest amount a monthly payment ceiling can finance.
  static const String maxAffordablePrice = 'max_affordable_price';

  /// Trade-in equity from value and loan payoff.
  static const String tradeEquity = 'trade_equity';

  /// Lease payment from the lease terms.
  static const String estimateLease = 'estimate_lease';

  /// A payment checked against income and debt.
  static const String assessAffordability = 'assess_affordability';

  /// Multi-year cost of ownership.
  static const String ownershipCost = 'ownership_cost';

  /// Records facts the person shared.
  static const String updateProfile = 'update_profile';

  /// Changes the live vehicle search filters.
  static const String updateSearch = 'update_search';

  /// Finds listings, opening a results page when none have been read.
  static const String findVehicles = 'find_vehicles';

  /// Reads the open web page or a URL.
  static const String readPage = 'read_page';

  /// Shows a component on screen.
  static const String present = 'present';

  /// Every spec, in prompt order.
  static final List<ToolSpec> all = [
    ToolSpec(
      name: estimatePayment,
      description:
          'Monthly payment and purchase breakdown for a vehicle. Use for ANY payment or cost question; never estimate yourself.',
      parameters: _obj(
        {
          'price': _num('vehicle price, dollars'),
          'term_months': _int(),
          'credit_band': _str(null, _bands),
          'apr': _num('exact APR as decimal, only if the user gave one'),
          'is_new': _bool('default false'),
          'down_payment': _num(),
          'sales_tax_rate': _num('decimal, default 0'),
          'fees': _num(),
          'trade_value': _num(),
          'trade_payoff': _num(),
          'roll_negative_equity': _bool('default true'),
        },
        ['price', 'term_months', 'credit_band'],
      ),
    ),
    ToolSpec(
      name: maxAffordablePrice,
      description:
          'Highest amount a monthly payment ceiling can finance. Use when the user says what they can pay per month.',
      parameters: _obj(
        {
          'payment_ceiling': _num(),
          'term_months': _int(),
          'credit_band': _str(null, _bands),
          'apr': _num('decimal, optional'),
          'is_new': _bool(),
        },
        ['payment_ceiling', 'term_months', 'credit_band'],
      ),
    ),
    ToolSpec(
      name: tradeEquity,
      description:
          'Trade-in equity from value and loan payoff. Use whenever the user owes on their current vehicle.',
      parameters: _obj(
        {'estimated_value': _num(), 'payoff': _num()},
        ['estimated_value', 'payoff'],
      ),
    ),
    ToolSpec(
      name: estimateLease,
      description: 'Lease payment from cap cost, residual, money factor, term.',
      parameters: _obj(
        {
          'capitalized_cost': _num(),
          'residual_value': _num(),
          'money_factor': _num('e.g. 0.00125'),
          'term_months': _int(),
          'cap_reduction': _num(),
          'sales_tax_rate': _num('decimal'),
        },
        ['capitalized_cost', 'residual_value', 'money_factor', 'term_months'],
      ),
    ),
    ToolSpec(
      name: assessAffordability,
      description: 'Check a payment against income and debt; returns warnings, never a yes/no.',
      parameters: _obj(
        {
          'monthly_gross_income': _num(),
          'monthly_debt_payments': _num(),
          'proposed_payment': _num(),
          'term_months': _int(),
          'payment_ceiling': _num(),
        },
        ['monthly_gross_income', 'proposed_payment', 'term_months'],
      ),
    ),
    ToolSpec(
      name: ownershipCost,
      description:
          'Rough multi-year cost of ownership (depreciation, fuel, insurance, maintenance, taxes).',
      parameters: _obj(
        {
          'vehicle_class': _str(null, _classes),
          'purchase_price': _num(),
          'miles_per_year': _int(),
          'fuel_type': _str(null, ['gasoline', 'hybrid', 'electric']),
          'efficiency': _num('mpg, or miles per kWh for electric'),
          'years': _int('default 5'),
          'vehicle_age_years': _int(),
          'insurance_band': _str(null, ['low', 'average', 'high']),
          'sales_tax_rate': _num(),
        },
        ['vehicle_class', 'purchase_price', 'miles_per_year', 'fuel_type', 'efficiency'],
      ),
    ),
    ToolSpec(
      name: updateProfile,
      description:
          'Record facts the user shared: needs, wants, budget, credit, trade-in, shopping mode. Call as soon as they say one. Label an item need/want only if the user did.',
      parameters: _obj({
        'items': {
          'type': 'array',
          'items': _obj(
            {
              'label': _str(),
              'kind': _str(null, ['need', 'want', 'unlabeled']),
            },
            ['label', 'kind'],
          ),
        },
        'payment_ceiling': _num(),
        'down_payment': _num(),
        'credit_band': _str(null, _bands),
        'credit_score': _int(),
        'monthly_gross_income': _num(),
        'trade_value': _num(),
        'trade_payoff': _num(),
        'shopping_mode': _str(
          'browsing=just looking, dreaming=for fun, practical, buying=buying now',
          ['browsing', 'dreaming', 'practical', 'buying'],
        ),
      }),
    ),
    ToolSpec(
      name: updateSearch,
      changesUi: true,
      description:
          'Set or change the vehicle search filters from what the user said; the listing site '
          'updates on screen at once. Call it instead of asking what kind of vehicle when they '
          'already implied it: "sports car" is body_style coupe, "dream car" means no max_price, '
          '"something for the family" is suv or van. Pass only the fields that change; "any" clears one.',
      parameters: _obj({
        'body_style': _str(null, [...SearchQueryBodyStyles.values, 'any']),
        'max_price': _num('dollars'),
        'min_price': _num('dollars'),
        'make': _str(),
        'model': _str(),
        'max_mileage': _int(),
        'min_year': _int(),
        'keywords': _str('free text the site should search for'),
      }),
    ),
    ToolSpec(
      name: findVehicles,
      description:
          'Find vehicles for sale that fit a budget, body style or keywords; opens and reads a '
          'results page when needed. Call as soon as the user names what they want (e.g. an SUV '
          'under 50000). Use estimate_payment on a result before quoting a payment.',
      parameters: _obj({
        'max_price': _num(),
        'vehicle_class': _str(null, _classes),
        'min_seats': _int(),
        'max_mileage': _int(),
        'keywords': _str(),
        'limit': _int('default 5'),
      }),
    ),
    ToolSpec(
      name: readPage,
      description:
          'Read the open web page (or a URL) and return its facts. Use figures found as INPUTS to finance tools.',
      parameters: _obj({'url': _str(), 'question': _str('what to look for')}),
    ),
    ToolSpec(
      name: present,
      changesUi: true,
      description:
          'Show something on screen. After a tool returns: component + result_id. To ask a question with a few options or to collect numbers: choice, multi_choice or input_form with props instead of prose.',
      parameters: _obj(
        {
          'component': _str('registry id'),
          'result_id': _str('from a tool result'),
          'surface': _str(null, ['docked', 'fullscreen']),
          'title': _str(),
          'highlights': {
            'type': 'array',
            'items': _str(),
            'description': 'result field names to emphasize',
          },
          'props': {
            'type': 'object',
            'description':
                'choice/multi_choice: {question, options:[{id,label}]}; input_form: {title, fields:[{id,label,type(number|currency|percent|text|select),options?}]}',
          },
        },
        ['component'],
      ),
    ),
  ];

  /// Looks up a spec by name; throws [ArgumentError] when there is none.
  static ToolSpec byName(String name) => all.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'unknown tool'),
  );
}
