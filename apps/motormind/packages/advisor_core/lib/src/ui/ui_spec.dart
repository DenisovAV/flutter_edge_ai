/// Where the advisor surface is.
enum SurfaceState { collapsed, docked, fullscreen }

/// A component the model may ask the app to render. The registry is the
/// whole vocabulary: anything not listed cannot be requested, which is what
/// keeps "the model composes the screen" safe.
class UiComponent {
  const UiComponent({
    required this.id,
    required this.description,
    required this.acceptsTools,
    this.defaultSurface = SurfaceState.docked,
  });

  final String id;
  final String description;

  /// Tool names whose results this component can render.
  final Set<String> acceptsTools;
  final SurfaceState defaultSurface;
}

abstract final class ComponentRegistry {
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
    description: 'One listing.',
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
    description: 'What was read from a web page, with its source URL.',
    acceptsTools: {'read_page'},
  );
  static const questionChips = UiComponent(
    id: 'question_chips',
    description: 'Tappable answers to a question the advisor asked (tone, need or want, yes or no).',
    acceptsTools: {},
  );

  static const List<UiComponent> all = [
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
    questionChips,
  ];

  static UiComponent? byId(String id) => all.where((c) => c.id == id).firstOrNull;

  /// The list handed to the model in the system prompt.
  static String describeForPrompt() => all.map((c) => '- ${c.id}: ${c.description}').join('\n');
}

/// A validated `present` tool call.
class PresentRequest {
  const PresentRequest({required this.component, required this.resultId, required this.surface, this.title});

  final UiComponent component;
  final String resultId;
  final SurfaceState surface;
  final String? title;

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
      errors.add('unknown component "$id"; choose one of: ${ComponentRegistry.all.map((c) => c.id).join(', ')}');
    }
    final resultId = args['result_id']?.toString();
    if (resultId == null || resultId.isEmpty) {
      if (component == null || component.acceptsTools.isNotEmpty) errors.add('result_id is required');
    } else if (resultTool == null) {
      errors.add('result_id "$resultId" does not match any tool result in this conversation');
    } else if (component != null && component.acceptsTools.isNotEmpty && !component.acceptsTools.contains(resultTool)) {
      errors.add('component "${component.id}" cannot render a $resultTool result; it accepts ${component.acceptsTools.join(', ')}');
    }
    SurfaceState? surface;
    final rawSurface = args['surface']?.toString();
    if (rawSurface != null) {
      surface = SurfaceState.values.where((s) => s.name == rawSurface).firstOrNull;
      if (surface == null || surface == SurfaceState.collapsed) {
        errors.add('surface must be "docked" or "fullscreen"');
      }
    }
    if (errors.isNotEmpty || component == null) return (request: null, errors: errors);
    return (
      request: PresentRequest(
        component: component,
        resultId: resultId ?? '',
        surface: surface ?? component.defaultSurface,
        title: args['title']?.toString(),
      ),
      errors: const [],
    );
  }
}
