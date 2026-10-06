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
    this.appOwned = false,
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

  /// True for components the app shows on its own (bound to app state). They
  /// are left out of the model's vocabulary so they cost no prompt tokens.
  final bool appOwned;
}

List<String> _validateOptions(Map<String, Object?> props, {required int min, required int max}) {
  final errors = <String>[];
  final question = props['question'];
  if (question is! String || question.trim().isEmpty) errors.add('props.question is required');
  final options = props['options'];
  if (options is! List || options.length < min) {
    errors.add('props.options must be a list of at least $min items');
    return errors;
  }
  if (options.length > max) {
    options.removeRange(max, options.length); // keep the first [max]; do not refuse
  }
  for (final o in options) {
    if (o is! Map || o['id'] is! String || o['label'] is! String) {
      errors.add('each option needs string "id" and "label"');
      break;
    }
    // Long labels are truncated at render time rather than refused: a
    // refused prompt leaves the person with nothing to tap.
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
    description: 'Payment, amount financed, cash at signing.',
    acceptsTools: {'estimate_payment'},
  );
  static const paymentBreakdown = UiComponent(
    id: 'payment_breakdown',
    description: 'Full purchase breakdown.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const amortizationChart = UiComponent(
    id: 'amortization_chart',
    description: 'Principal vs interest over time.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const affordabilityGauge = UiComponent(
    id: 'affordability_gauge',
    description: 'Affordability ratios and warnings.',
    acceptsTools: {'assess_affordability', 'max_affordable_price'},
  );
  static const tradeEquityCard = UiComponent(
    id: 'trade_equity_card',
    description: 'Trade value, payoff, equity.',
    acceptsTools: {'trade_equity'},
  );
  static const leaseVsBuy = UiComponent(
    id: 'lease_vs_buy',
    description: 'Lease vs buy side by side.',
    acceptsTools: {'estimate_lease', 'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const ownershipCost = UiComponent(
    id: 'ownership_cost',
    description: 'Cost of ownership by category.',
    acceptsTools: {'ownership_cost'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const vehicleCard = UiComponent(
    id: 'vehicle_card',
    description: 'One listing.',
    acceptsTools: {'find_vehicles', 'read_page'},
  );
  static const vehicleCompare = UiComponent(
    id: 'vehicle_compare',
    description: '2–3 listings compared.',
    acceptsTools: {'find_vehicles'},
    defaultSurface: SurfaceState.fullscreen,
  );
  static const pageExtract = UiComponent(
    id: 'page_extract',
    description: 'Facts read from a web page.',
    acceptsTools: {'read_page'},
  );

  // --- interaction components ---------------------------------------------
  static final choice = UiComponent(
    id: 'choice',
    description:
        'Question with 2–6 tappable answers; use instead of an open question when the answer is one of a few options.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, min: 2, max: 6),
  );
  static final multiChoice = UiComponent(
    id: 'multi_choice',
    description: 'Question with 2–8 answers where several may apply.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, min: 2, max: 8),
  );

  /// The live vehicle filters (type, price, miles, site). App-owned: it is
  /// bound to the search state, so it needs no props and never retires.
  static final searchFilters = UiComponent(
    id: 'search_filters',
    description: 'the live vehicle filters; the app keeps it current',
    acceptsTools: const {},
    validateProps: (_) => const [],
    appOwned: true,
  );
  static final inputForm = UiComponent(
    id: 'input_form',
    description: 'Short form (1–6 fields) to collect numbers before a finance tool.',
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
    searchFilters,
  ];

  static UiComponent? byId(String id) => all.where((c) => c.id == id).firstOrNull;

  /// What the model may present.
  static Iterable<UiComponent> get forModel => all.where((c) => !c.appOwned);

  /// The component the app shows for a tool result when the model computed
  /// something and did not call `present` (DD principle 1: the model decides
  /// what to show, but a computed number never stays hidden in prose).
  static UiComponent? defaultFor(String tool) => switch (tool) {
    'estimate_payment' => paymentSummary,
    'trade_equity' => tradeEquityCard,
    'assess_affordability' || 'max_affordable_price' => affordabilityGauge,
    'estimate_lease' => leaseVsBuy,
    'ownership_cost' => ownershipCost,
    'find_vehicles' => vehicleCard,
    'read_page' => pageExtract,
    _ => null,
  };

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
