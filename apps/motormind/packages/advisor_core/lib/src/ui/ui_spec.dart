/// Where the advisor surface is.
enum SurfaceState { collapsed, docked, fullscreen }

/// A component the model may ask the app to render. The registry is the
/// whole vocabulary: anything not listed cannot be requested, which is what
/// keeps "the model composes the screen" safe.
///
/// Two kinds of component exist:
/// - **result components** render a tool result (`acceptsTools` non-empty);
/// - **interaction components** (`choice`, `multiChoice`, `inputForm`) are
///   built from `props` the model supplies and exist so the model can offer
///   structured answers instead of asking the user to type. Every interaction
///   component also renders an implicit "something else" escape that opens free
///   text, so the user is never trapped in the model's options.
class UiComponent {
  const UiComponent({
    required this.id,
    required this.description,
    required this.acceptsTools,
    this.defaultSurface = SurfaceState.docked,
    this.validateProps,
  });

  final String id;
  final String description;

  /// Tool names whose results this component can render. Empty for
  /// interaction components.
  final Set<String> acceptsTools;
  final SurfaceState defaultSurface;

  /// Returns problems with `props`, or an empty list.
  final List<String> Function(Map<String, Object?> props)? validateProps;

  bool get isInteraction => acceptsTools.isEmpty;
}

List<String> _validateOptions(Map<String, Object?> props, {required int min, required int max}) {
  final errors = <String>[];
  final question = props['question'];
  if (question is! String || question.trim().isEmpty) errors.add('props.question is required');
  final options = props['options'];
  if (options is! List || options.length < min || options.length > max) {
    errors.add('props.options must be a list of $min to $max items');
    return errors;
  }
  for (final o in options) {
    if (o is! Map || o['id'] is! String || o['label'] is! String) {
      errors.add('each option needs string "id" and "label"');
      break;
    }
    if ((o['label'] as String).length > 40) {
      errors.add('option labels must be 40 characters or fewer: "${o['label']}"');
    }
  }
  return errors;
}

const Set<String> _fieldTypes = {'number', 'currency', 'percent', 'text', 'select'};

List<String> _validateFields(Map<String, Object?> props) {
  final errors = <String>[];
  final fields = props['fields'];
  if (fields is! List || fields.isEmpty || fields.length > 6) {
    return ['props.fields must be a list of 1 to 6 fields'];
  }
  for (final f in fields) {
    if (f is! Map || f['id'] is! String || f['label'] is! String) {
      errors.add('each field needs string "id" and "label"');
      continue;
    }
    final type = f['type'];
    if (type is! String || !_fieldTypes.contains(type)) {
      errors.add('field "${f['id']}" type must be one of ${_fieldTypes.join(', ')}');
    }
    if (type == 'select' && f['options'] is! List) {
      errors.add('select field "${f['id']}" needs options');
    }
  }
  return errors;
}

abstract final class ComponentRegistry {
  // --- result components --------------------------------------------------
  static const paymentSummary = UiComponent(
    id: 'payment_summary',
    description: 'One card: monthly payment, amount financed, cash at signing.',
    acceptsTools: {'estimate_payment'},
  );
  static const paymentBreakdown = UiComponent(
    id: 'payment_breakdown',
    description: 'Full purchase breakdown with assumptions and what-if variants.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const amortizationChart = UiComponent(
    id: 'amortization_chart',
    description: 'Principal versus interest over the term.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const affordabilityGauge = UiComponent(
    id: 'affordability_gauge',
    description: 'Payment-to-income and debt-to-income with guideline markers and warnings.',
    acceptsTools: {'assess_affordability', 'max_affordable_price'},
  );
  static const tradeEquityCard = UiComponent(
    id: 'trade_equity_card',
    description: 'Value, payoff and equity, with negative equity stated plainly.',
    acceptsTools: {'trade_equity'},
  );
  static const leaseVsBuy = UiComponent(
    id: 'lease_vs_buy',
    description: 'Side-by-side lease and purchase estimates.',
    acceptsTools: {'estimate_lease', 'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const ownershipCost = UiComponent(
    id: 'ownership_cost',
    description: 'Stacked cost of ownership by category.',
    acceptsTools: {'ownership_cost'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const vehicleCard = UiComponent(
    id: 'vehicle_card',
    description: 'One listing, with its image and source link when it came from a page.',
    acceptsTools: {'find_vehicles', 'read_page'},
  );
  static const vehicleCompare = UiComponent(
    id: 'vehicle_compare',
    description: 'Two or three listings side by side with payment and ownership cost.',
    acceptsTools: {'find_vehicles'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const pageExtract = UiComponent(
    id: 'page_extract',
    description:
        'What was read from a web page: key facts, images, and a link to open the full page.',
    acceptsTools: {'read_page'},
  );

  // --- interaction components ---------------------------------------------
  static final choice = UiComponent(
    id: 'choice',
    description:
        'A question with 2 to 6 tappable answers (single select). Use instead of an open question '
        'whenever the answer is one of a few options. props: {question, options: [{id, label}]}. '
        'The user can always pick "something else" and type.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, min: 2, max: 6),
  );
  static final multiChoice = UiComponent(
    id: 'multi_choice',
    description:
        'A question with 2 to 8 tappable answers where several may apply (e.g. must-have features). '
        'props: {question, options: [{id, label}]}.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, min: 2, max: 8),
  );
  static final inputForm = UiComponent(
    id: 'input_form',
    description:
        'A short form of 1 to 6 typed fields (number, currency, percent, text, select) for values '
        'you need before calling a finance tool, e.g. price, down payment, payoff. props: '
        '{title, fields: [{id, label, type, options?}]}. Faster and more exact than asking in prose.',
    acceptsTools: const {},
    validateProps: _validateFields,
  );

  static final List<UiComponent> all = [
    paymentSummary,
    paymentBreakdown,
    amortizationChart,
    affordabilityGauge,
    tradeEquityCard,
    leaseVsBuy,
    ownershipCost,
    vehicleCard,
    vehicleCompare,
    pageExtract,
    choice,
    multiChoice,
    inputForm,
  ];

  static UiComponent? byId(String id) => all.where((c) => c.id == id).firstOrNull;

  /// The list handed to the model in the system prompt.
  static String describeForPrompt() => all.map((c) => '- ${c.id}: ${c.description}').join('\n');
}

/// A validated `present` tool call.
class PresentRequest {
  const PresentRequest({
    required this.component,
    required this.surface,
    this.resultId,
    this.title,
    this.highlights = const [],
    this.props = const {},
  });

  final UiComponent component;
  final SurfaceState surface;

  /// The tool result to render; null for interaction components.
  final String? resultId;
  final String? title;

  /// Field names in the result the conversation is about, for emphasis.
  /// Names, never values, so the guard is not involved.
  final List<String> highlights;

  /// Model-supplied props for interaction components, already validated.
  final Map<String, Object?> props;

  /// Validates the model's arguments against the registry and the tool that
  /// produced [resultTool]. Returns a request or a list of problems the model
  /// is told about.
  static ({PresentRequest? request, List<String> errors}) validate(
    Map<String, Object?> args, {
    required String? resultTool,
  }) {
    final errors = <String>[];
    final id = args['component']?.toString();
    final component = id == null ? null : ComponentRegistry.byId(id);
    if (component == null) {
      errors.add(
        'unknown component "$id"; choose one of: ${ComponentRegistry.all.map((c) => c.id).join(', ')}',
      );
      return (request: null, errors: errors);
    }

    final resultId = args['result_id']?.toString();
    if (component.isInteraction) {
      final rawProps = args['props'];
      final props = rawProps is Map ? rawProps.cast<String, Object?>() : <String, Object?>{};
      errors.addAll(component.validateProps?.call(props) ?? const []);
    } else if (resultId == null || resultId.isEmpty) {
      errors.add('result_id is required for ${component.id}');
    } else if (resultTool == null) {
      errors.add('result_id "$resultId" does not match any tool result in this conversation');
    } else if (!component.acceptsTools.contains(resultTool)) {
      errors.add(
        'component "${component.id}" cannot render a $resultTool result; it accepts '
        '${component.acceptsTools.join(', ')}',
      );
    }

    SurfaceState? surface;
    final rawSurface = args['surface']?.toString();
    if (rawSurface != null) {
      surface = SurfaceState.values.where((s) => s.name == rawSurface).firstOrNull;
      if (surface == null || surface == SurfaceState.collapsed) {
        errors.add('surface must be "docked" or "fullscreen"');
      }
    }

    final rawHighlights = args['highlights'];
    final highlights = <String>[];
    if (rawHighlights != null) {
      if (rawHighlights is List && rawHighlights.every((h) => h is String)) {
        highlights.addAll(rawHighlights.cast<String>());
      } else {
        errors.add('highlights must be a list of field names');
      }
    }

    if (errors.isNotEmpty) return (request: null, errors: errors);
    final rawProps = args['props'];
    return (
      request: PresentRequest(
        component: component,
        surface: surface ?? component.defaultSurface,
        resultId: component.isInteraction ? null : resultId,
        title: args['title']?.toString(),
        highlights: highlights,
        props: rawProps is Map ? rawProps.cast<String, Object?>() : const {},
      ),
      errors: const [],
    );
  }
}
