/// Where Motormind's surface sits on screen.
enum SurfaceState {
  /// Hidden; nothing but the conversation is shown.
  collapsed,

  /// Sharing the screen with the conversation.
  docked,

  /// Covering the conversation.
  fullscreen,
}

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
  /// Creates a component; see the class comment for the two kinds.
  const UiComponent({
    required this.id,
    required this.description,
    required this.acceptsTools,
    this.defaultSurface = SurfaceState.docked,
    this.validateProps,
    this.appOwned = false,
  });

  /// Registry id the model uses in `present(component)`.
  final String id;

  /// What the component shows, in the words the prompt uses.
  final String description;

  /// Tool names whose results this component can render. Empty for
  /// interaction components.
  final Set<String> acceptsTools;

  /// Where the component opens when the model does not say.
  final SurfaceState defaultSurface;

  /// Returns problems with `props`, or an empty list. Must not change the
  /// props: anything the app trims rather than refuses is trimmed by
  /// [PresentRequest.validate] on its own copy.
  final List<String> Function(Map<String, Object?> props)? validateProps;

  /// True for components the app shows on its own (bound to app state). They
  /// are left out of the model's vocabulary so they cost no prompt tokens.
  final bool appOwned;

  /// True for interaction components, which render from props rather than
  /// from a tool result.
  bool get isInteraction => acceptsTools.isEmpty;
}

/// Fewest answers a `choice` or `multi_choice` may offer: one answer is a
/// statement, not a question.
const int minOptions = 2;

/// Most answers a `choice` may offer; more than this stops fitting on a
/// phone screen without scrolling, and extras are dropped, not refused.
const int maxChoiceOptions = 6;

/// Most answers a `multi_choice` may offer; checkboxes are shorter than
/// buttons, so a few more fit.
const int maxMultiChoiceOptions = 8;

/// Most fields an `input_form` may ask for before it is a tax return.
const int maxFormFields = 6;

/// Validates the `question` and `options` of a choice-style component
/// without changing them. More than [max] options is not an error; the
/// request keeps the first [max] (see [PresentRequest.validate]), because a
/// refused prompt leaves the person with nothing to tap.
List<String> _validateOptions(Map<String, Object?> props, {required int max}) {
  final errors = <String>[];
  final question = props['question'];
  if (question is! String || question.trim().isEmpty) errors.add('props.question is required');
  final options = props['options'];
  if (options is! List || options.length < minOptions) {
    errors.add('props.options must be a list of at least $minOptions items');
    return errors;
  }
  for (final o in options.take(max)) {
    if (o is! Map || o['id'] is! String || o['label'] is! String) {
      errors.add('each option needs string "id" and "label"');
      break;
    }
    // Long labels are truncated at render time rather than refused, for the
    // same reason extra options are dropped.
  }
  return errors;
}

/// Field types `input_form` can render.
const Set<String> _fieldTypes = {'number', 'currency', 'percent', 'text', 'select'};

List<String> _validateFields(Map<String, Object?> props) {
  final errors = <String>[];
  final fields = props['fields'];
  if (fields is! List || fields.isEmpty || fields.length > maxFormFields) {
    return ['props.fields must be a list of 1 to $maxFormFields fields'];
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

/// Every component the model, or the app on its own, may show; see
/// [UiComponent] for the two kinds.
abstract final class ComponentRegistry {
  // --- result components --------------------------------------------------
  /// Payment, amount financed and cash at signing from `estimate_payment`.
  static const paymentSummary = UiComponent(
    id: 'payment_summary',
    description: 'Payment, amount financed, cash at signing.',
    acceptsTools: {'estimate_payment'},
  );

  /// Full purchase breakdown from `estimate_payment`.
  static const paymentBreakdown = UiComponent(
    id: 'payment_breakdown',
    description: 'Full purchase breakdown.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );

  /// Principal against interest over the term, from `estimate_payment`.
  static const amortizationChart = UiComponent(
    id: 'amortization_chart',
    description: 'Principal vs interest over time.',
    acceptsTools: {'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );

  /// Ratios and warnings from `assess_affordability` or
  /// `max_affordable_price`.
  static const affordabilityGauge = UiComponent(
    id: 'affordability_gauge',
    description: 'Affordability ratios and warnings.',
    acceptsTools: {'assess_affordability', 'max_affordable_price'},
  );

  /// Value, payoff and equity from `trade_equity`.
  static const tradeEquityCard = UiComponent(
    id: 'trade_equity_card',
    description: 'Trade value, payoff, equity.',
    acceptsTools: {'trade_equity'},
  );

  /// Lease and purchase side by side, from `estimate_lease` or
  /// `estimate_payment`.
  static const leaseVsBuy = UiComponent(
    id: 'lease_vs_buy',
    description: 'Lease vs buy side by side.',
    acceptsTools: {'estimate_lease', 'estimate_payment'},
    defaultSurface: SurfaceState.fullscreen,
  );

  /// Cost of ownership by category from `ownership_cost`.
  static const ownershipCost = UiComponent(
    id: 'ownership_cost',
    description: 'Cost of ownership by category.',
    acceptsTools: {'ownership_cost'},
    defaultSurface: SurfaceState.fullscreen,
  );

  /// One listing from `find_vehicles` or `read_page`.
  static const vehicleCard = UiComponent(
    id: 'vehicle_card',
    description: 'One listing.',
    acceptsTools: {'find_vehicles', 'read_page'},
  );

  /// Two or three listings compared, from `find_vehicles`.
  static const vehicleCompare = UiComponent(
    id: 'vehicle_compare',
    description: '2–3 listings compared.',
    acceptsTools: {'find_vehicles'},
    defaultSurface: SurfaceState.fullscreen,
  );

  /// Facts read from a web page by `read_page`.
  static const pageExtract = UiComponent(
    id: 'page_extract',
    description: 'Facts read from a web page.',
    acceptsTools: {'read_page'},
  );

  // --- interaction components ---------------------------------------------
  /// A question with [minOptions] to [maxChoiceOptions] tappable answers,
  /// one of which applies.
  static final choice = UiComponent(
    id: 'choice',
    description:
        'Question with $minOptions–$maxChoiceOptions tappable answers; use instead of an open '
        'question when the answer is one of a few options.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, max: maxChoiceOptions),
  );

  /// A question with [minOptions] to [maxMultiChoiceOptions] answers,
  /// several of which may apply.
  static final multiChoice = UiComponent(
    id: 'multi_choice',
    description:
        'Question with $minOptions–$maxMultiChoiceOptions answers where several may apply.',
    acceptsTools: const {},
    validateProps: (p) => _validateOptions(p, max: maxMultiChoiceOptions),
  );

  /// The live vehicle filters (type, price, miles, site). App-owned: it is
  /// bound to the search state, so it needs no props and is never answered or dismissed.
  static final searchFilters = UiComponent(
    id: 'search_filters',
    description: 'the live vehicle filters; the app keeps it current',
    acceptsTools: const {},
    validateProps: (_) => const [],
    appOwned: true,
  );

  /// A form of one to [maxFormFields] fields for collecting numbers before
  /// a finance tool runs.
  static final inputForm = UiComponent(
    id: 'input_form',
    description: 'Short form (1–$maxFormFields fields) to collect numbers before a finance tool.',
    acceptsTools: const {},
    validateProps: _validateFields,
  );

  /// Every component, result components first and app-owned ones last;
  /// unmodifiable.
  static final List<UiComponent> all = List.unmodifiable([
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
  ]);

  /// What the model may present: [all] without the app-owned components;
  /// unmodifiable.
  static final List<UiComponent> forModel = List.unmodifiable(all.where((c) => !c.appOwned));

  static final Map<String, UiComponent> _byId = {for (final c in all) c.id: c};

  /// Looks up a component by registry id, or null when there is none.
  static UiComponent? byId(String id) => _byId[id];

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

  /// One line per component in [forModel], for a prompt that lists what the
  /// model may present. App-owned components are left out: the model cannot
  /// request them, so listing them would only invite the attempt.
  static String describeForPrompt() =>
      forModel.map((c) => '- ${c.id}: ${c.description}').join('\n');
}

/// A validated `present` tool call.
class PresentRequest {
  /// Creates a request directly; [validate] builds one from model arguments.
  const PresentRequest({
    required this.component,
    required this.surface,
    this.resultId,
    this.title,
    this.highlights = const [],
    this.props = const {},
  });

  /// The component to show.
  final UiComponent component;

  /// Where to show it; never [SurfaceState.collapsed].
  final SurfaceState surface;

  /// The tool result to render; null for interaction components.
  final String? resultId;

  /// Optional title the model supplied for the card.
  final String? title;

  /// Field names in the result the conversation is about, for emphasis.
  /// Names, never values, so the guard is not involved.
  final List<String> highlights;

  /// Model-supplied props for interaction components, already validated and
  /// trimmed to what the component renders; empty for result components.
  final Map<String, Object?> props;

  /// Validates the model's arguments against the registry and the tool that
  /// produced [resultTool]. Returns a request or a list of problems the model
  /// is told about. The arguments are never changed: props are copied before
  /// extra options are dropped.
  static ({PresentRequest? request, List<String> errors}) validate(
    Map<String, Object?> args, {
    required String? resultTool,
  }) {
    final errors = <String>[];
    final id = args['component']?.toString();
    final component = id == null ? null : ComponentRegistry.byId(id);
    if (component == null) {
      errors.add(
        'unknown component "$id"; choose one of: '
        '${ComponentRegistry.forModel.map((c) => c.id).join(', ')}',
      );
      return (request: null, errors: errors);
    }

    final resultId = args['result_id']?.toString();
    final props = component.isInteraction ? _propsOf(component, args['props']) : null;
    if (props != null) {
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

    final surface = _parseSurface(args['surface'], errors);
    final highlights = _parseHighlights(args['highlights'], errors);
    if (errors.isNotEmpty) return (request: null, errors: errors);
    return (
      request: PresentRequest(
        component: component,
        surface: surface ?? component.defaultSurface,
        resultId: props == null ? resultId : null,
        title: args['title']?.toString(),
        highlights: highlights,
        props: props ?? const {},
      ),
      errors: const [],
    );
  }

  /// A copy of the model's props for [component], with more options than
  /// the component shows trimmed to the first ones. The copy is what keeps
  /// the caller's map intact.
  static Map<String, Object?> _propsOf(UiComponent component, Object? raw) {
    final props = raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
    final max = switch (component.id) {
      'choice' => maxChoiceOptions,
      'multi_choice' => maxMultiChoiceOptions,
      _ => null,
    };
    final options = props['options'];
    if (max != null && options is List && options.length > max) {
      props['options'] = options.take(max).toList();
    }
    return props;
  }

  /// The requested surface, or null when the model left it to the default.
  /// Adds to [errors] when it is unknown or collapsed.
  static SurfaceState? _parseSurface(Object? raw, List<String> errors) {
    if (raw == null) return null;
    final surface = SurfaceState.values.where((s) => s.name == raw.toString()).firstOrNull;
    if (surface == null || surface == SurfaceState.collapsed) {
      errors.add('surface must be "docked" or "fullscreen"');
      return null;
    }
    return surface;
  }

  /// The field names to emphasize; adds to [errors] when they are not a
  /// list of strings.
  static List<String> _parseHighlights(Object? raw, List<String> errors) {
    if (raw == null) return const [];
    if (raw is List && raw.every((h) => h is String)) return raw.cast<String>().toList();
    errors.add('highlights must be a list of field names');
    return const [];
  }
}
