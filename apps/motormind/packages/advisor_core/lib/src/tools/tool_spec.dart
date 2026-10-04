/// A tool the model may call. Mirrors the shape inference SDKs expect
/// (name, description, JSON-schema parameters) without depending on one.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    this.changesUi = false,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// True when the tool's purpose is to change what is on screen rather than
  /// to compute something.
  final bool changesUi;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}

Map<String, Object?> _number(String description) => {'type': 'number', 'description': description};
Map<String, Object?> _integer(String description) => {
  'type': 'integer',
  'description': description,
};
Map<String, Object?> _string(String description, {List<String>? enumValues}) => {
  'type': 'string',
  'description': description,
  'enum': ?enumValues,
};
Map<String, Object?> _boolean(String description) => {
  'type': 'boolean',
  'description': description,
};

/// Every tool Motormind offers the model, in the order they are described in
/// the system prompt. Descriptions tell the model WHEN to call; keep them
/// instructional, not decorative.
abstract final class AdvisorTools {
  static const String estimatePayment = 'estimate_payment';
  static const String maxAffordablePrice = 'max_affordable_price';
  static const String tradeEquity = 'trade_equity';
  static const String estimateLease = 'estimate_lease';
  static const String assessAffordability = 'assess_affordability';
  static const String ownershipCost = 'ownership_cost';
  static const String updateProfile = 'update_profile';
  static const String findVehicles = 'find_vehicles';
  static const String readPage = 'read_page';
  static const String present = 'present';

  static final List<ToolSpec> all = [
    ToolSpec(
      name: estimatePayment,
      description:
          'Compute the monthly payment and full purchase breakdown for a vehicle. Call this for ANY '
          'payment, total cost or finance-charge question instead of estimating yourself. Rates come '
          'from the credit band unless the user gave an exact APR.',
      parameters: {
        'type': 'object',
        'properties': {
          'price': _number('Vehicle price in dollars before tax and fees.'),
          'term_months': _integer('Loan term in months, e.g. 60.'),
          'credit_band': _string(
            'The user\'s credit band.',
            enumValues: ['excellent', 'good', 'fair', 'poor', 'rebuilding'],
          ),
          'apr': _number(
            'Optional exact APR as a decimal (0.065 for 6.5%). Omit to use the band rate.',
          ),
          'is_new': _boolean('True for a new vehicle, false for used. Default false.'),
          'down_payment': _number('Cash down in dollars. Default 0.'),
          'sales_tax_rate': _number('Sales tax rate as a decimal. Default 0.'),
          'fees': _number('Dealer, doc, title and registration fees in dollars. Default 0.'),
          'trade_value': _number('Estimated value of the trade-in, if any.'),
          'trade_payoff': _number('Amount still owed on the trade-in, if any.'),
          'roll_negative_equity': _boolean(
            'Finance any negative equity (true) or pay it in cash (false). Default true.',
          ),
        },
        'required': ['price', 'term_months', 'credit_band'],
      },
    ),
    ToolSpec(
      name: maxAffordablePrice,
      description:
          'Compute the highest vehicle price a monthly payment ceiling supports. Call this when the user '
          'states what they can pay per month and asks what they can afford.',
      parameters: {
        'type': 'object',
        'properties': {
          'payment_ceiling': _number('Maximum monthly payment in dollars.'),
          'term_months': _integer('Loan term in months.'),
          'credit_band': _string(
            'The user\'s credit band.',
            enumValues: ['excellent', 'good', 'fair', 'poor', 'rebuilding'],
          ),
          'apr': _number('Optional exact APR as a decimal.'),
          'is_new': _boolean('True for new, false for used. Default false.'),
        },
        'required': ['payment_ceiling', 'term_months', 'credit_band'],
      },
    ),
    ToolSpec(
      name: tradeEquity,
      description:
          'Compute trade-in equity from the vehicle\'s estimated value and the loan payoff. Call this '
          'whenever the user owes money on their current vehicle.',
      parameters: {
        'type': 'object',
        'properties': {
          'estimated_value': _number('What the current vehicle is worth in dollars.'),
          'payoff': _number('Amount still owed in dollars.'),
        },
        'required': ['estimated_value', 'payoff'],
      },
    ),
    ToolSpec(
      name: estimateLease,
      description:
          'Compute a lease payment from capitalized cost, residual value, money factor and term. Call '
          'this for any lease question; ask for the residual and money factor if the user has an offer.',
      parameters: {
        'type': 'object',
        'properties': {
          'capitalized_cost': _number('Agreed price plus capitalized fees, in dollars.'),
          'residual_value': _number('Residual value in dollars at lease end.'),
          'money_factor': _number('Money factor, e.g. 0.00125.'),
          'term_months': _integer('Lease term in months.'),
          'cap_reduction': _number('Down payment applied to the lease. Default 0.'),
          'sales_tax_rate': _number('Monthly use tax rate as a decimal. Default 0.'),
        },
        'required': ['capitalized_cost', 'residual_value', 'money_factor', 'term_months'],
      },
    ),
    ToolSpec(
      name: assessAffordability,
      description:
          'Check a proposed payment against income and existing debt using common guidelines. Returns '
          'warnings, never a yes or no. Call this before presenting any payment above the user\'s ceiling.',
      parameters: {
        'type': 'object',
        'properties': {
          'monthly_gross_income': _number('Gross monthly income in dollars.'),
          'monthly_debt_payments': _number('Other monthly debt payments in dollars. Default 0.'),
          'proposed_payment': _number('The vehicle payment being considered.'),
          'term_months': _integer('Loan term in months.'),
          'payment_ceiling': _number('The user\'s stated maximum, if any.'),
        },
        'required': ['monthly_gross_income', 'proposed_payment', 'term_months'],
      },
    ),
    ToolSpec(
      name: ownershipCost,
      description:
          'Rough multi-year cost of ownership: depreciation, fuel or energy, insurance, maintenance, '
          'taxes and fees. Call this when the user asks what a vehicle really costs to own.',
      parameters: {
        'type': 'object',
        'properties': {
          'vehicle_class': _string('Vehicle class.', enumValues: ['car', 'suv', 'pickup', 'van']),
          'purchase_price': _number('Purchase price in dollars.'),
          'miles_per_year': _integer('Expected miles per year.'),
          'fuel_type': _string('Fuel type.', enumValues: ['gasoline', 'hybrid', 'electric']),
          'efficiency': _number('MPG for gasoline or hybrid; miles per kWh for electric.'),
          'years': _integer('Ownership years. Default 5.'),
          'vehicle_age_years': _integer('Age of the vehicle at purchase. Default 0.'),
          'insurance_band': _string('Insurance cost band.', enumValues: ['low', 'average', 'high']),
          'sales_tax_rate': _number('Sales tax rate as a decimal. Default 0.'),
        },
        'required': [
          'vehicle_class',
          'purchase_price',
          'miles_per_year',
          'fuel_type',
          'efficiency',
        ],
      },
    ),
    ToolSpec(
      name: updateProfile,
      description:
          'Record facts the user shared about themselves or what they are looking for. Call this as '
          'soon as the user states a need, a want, a budget, a credit band, a trade-in, or shifts how '
          'they are shopping. Do not label an item as a need or a want unless the user did.',
      parameters: {
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'description': 'Needs, wants or unlabeled preferences the user mentioned.',
            'items': {
              'type': 'object',
              'properties': {
                'label': _string('Short description, e.g. "seats 7" or "heated seats".'),
                'kind': _string(
                  'How the user framed it.',
                  enumValues: ['need', 'want', 'unlabeled'],
                ),
              },
              'required': ['label', 'kind'],
            },
          },
          'payment_ceiling': _number('Maximum monthly payment the user stated.'),
          'down_payment': _number('Cash the user can put down.'),
          'credit_band': _string(
            'Credit band.',
            enumValues: ['excellent', 'good', 'fair', 'poor', 'rebuilding'],
          ),
          'credit_score': _integer(
            'Numeric score if the user gave one; it will be mapped to a band.',
          ),
          'monthly_gross_income': _number('Gross monthly income if the user shared it.'),
          'trade_value': _number('Estimated value of a trade-in.'),
          'trade_payoff': _number('Payoff on a trade-in.'),
          'shopping_mode': _string(
            'How the user is shopping, inferred from what they say and updated when it shifts: '
            'browsing (just looking), dreaming (dream car, for fun), practical (realistic options), '
            'buying (buying now, detailed budgeting).',
            enumValues: ['browsing', 'dreaming', 'practical', 'buying'],
          ),
        },
      },
    ),
    ToolSpec(
      name: findVehicles,
      description:
          'Search the available inventory for vehicles matching the profile and any extra filters. '
          'Returns listings with prices; use estimate_payment on a listing before quoting a payment.',
      parameters: {
        'type': 'object',
        'properties': {
          'max_price': _number('Maximum price in dollars.'),
          'vehicle_class': _string('Vehicle class.', enumValues: ['car', 'suv', 'pickup', 'van']),
          'min_seats': _integer('Minimum seating.'),
          'max_mileage': _integer('Maximum odometer miles for used vehicles.'),
          'keywords': _string('Free-text keywords such as make, model or feature.'),
          'limit': _integer('Maximum number of results. Default 5.'),
        },
      },
    ),
    ToolSpec(
      name: readPage,
      description:
          'Read the web page currently open in the content area (or a URL the user gave) and return '
          'its cleaned text plus any price, mileage or year found. Use its figures as INPUTS to the '
          'finance tools; never restate them as your own estimate.',
      parameters: {
        'type': 'object',
        'properties': {
          'url': _string('Optional URL to open first. Omit to read the current page.'),
          'question': _string('What to look for on the page, in a few words.'),
        },
      },
    ),
    ToolSpec(
      name: present,
      changesUi: true,
      description:
          'Put something on screen. Two uses: (1) after a finance or search tool returns, show its '
          'result with a result component and its result_id; (2) when you need an answer or values '
          'from the user, offer a "choice", "multi_choice" or "input_form" with props instead of '
          'asking in prose. Structured answers are faster for the user and for you; always prefer '
          'them when the answer is one of a few options or a number. Use "fullscreen" for '
          'breakdowns with several numbers and "docked" for a single card or a question.',
      parameters: {
        'type': 'object',
        'properties': {
          'component': _string('Component id from the registry.'),
          'result_id': _string('The id of the tool result to render (result components only).'),
          'surface': _string('Where to show it.', enumValues: ['docked', 'fullscreen']),
          'title': _string('Short title for the card or screen.'),
          'highlights': {
            'type': 'array',
            'description': 'Field names in the result to emphasize, e.g. ["monthlyPayment"].',
            'items': {'type': 'string'},
          },
          'props': {
            'type': 'object',
            'description':
                'For interaction components: {question, options:[{id,label}]} for choice and '
                'multi_choice; {title, fields:[{id,label,type,options?}]} for input_form.',
          },
        },
        'required': ['component'],
      },
    ),
  ];

  static ToolSpec byName(String name) => all.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'unknown tool'),
  );
}
