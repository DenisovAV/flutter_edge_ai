import '../profile/buyer_profile.dart';
import '../tools/tool_spec.dart';
import '../ui/ui_spec.dart';

/// What the model is told about the canvas each turn (DD-R10).
class ViewportDescriptor {
  const ViewportDescriptor({
    required this.widthDp,
    required this.heightDp,
    this.keyboardVisible = false,
    this.posture = 'phone',
  });

  final double widthDp;
  final double heightDp;
  final bool keyboardVisible;

  /// `phone`, `wide` (tablet or unfolded foldable), or `folded`.
  final String posture;

  String describe() =>
      '${widthDp.round()}x${heightDp.round()} dp, $posture, keyboard ${keyboardVisible ? 'up' : 'down'}';
}

/// Assembles the system prompt from editable text sections plus the live
/// vocabulary (tools, components) and the live situation (profile, viewport).
/// The text sections are data (Markdown assets in the app, TQ46), not code.
class SystemPromptBuilder {
  const SystemPromptBuilder({
    required this.persona,
    required this.policy,
    required this.modeGuidance,
  });

  /// Who the advisor is and how it behaves.
  final String persona;

  /// The non-salesperson rules.
  final String policy;

  /// Tone and emphasis per shopping mode.
  final Map<ShoppingMode, String> modeGuidance;

  String build({
    required BuyerProfile profile,
    ViewportDescriptor? viewport,
    List<ToolSpec>? tools,
    List<UiComponent>? components,
  }) {
    final mode = profile.mode;
    final buffer = StringBuffer()
      ..writeln(persona.trim())
      ..writeln()
      ..writeln('# Rules')
      ..writeln(policy.trim())
      ..writeln()
      ..writeln('# Numbers')
      ..writeln(
        'Never compute or guess a dollar amount, rate, payment or percentage. Call a tool and '
        'repeat only the numbers it returns. If you lack an input, ask for it (prefer an '
        'input_form) rather than assuming it.',
      )
      ..writeln()
      ..writeln('# Showing things on screen')
      ..writeln(
        'After a tool returns, call `present` with a component and the result_id so the person '
        'sees the numbers; do not retype them. When you need an answer that is one of a few '
        'options or a number, call `present` with choice, multi_choice or input_form instead of '
        'asking in prose. Keep prose short when something is on screen that the person is '
        'deciding about. At most one structured prompt per turn.',
      )
      ..writeln()
      ..writeln('Components you can present:')
      ..writeln(ComponentRegistry.describeForPrompt())
      ..writeln();

    if (mode != null && modeGuidance[mode] != null) {
      buffer
        ..writeln('# Current shopping mode: ${mode.name}')
        ..writeln(modeGuidance[mode]!.trim())
        ..writeln();
    } else {
      buffer
        ..writeln('# Shopping mode')
        ..writeln(
          'Not known yet. Infer it from what the person says (browsing, dreaming, practical, '
          'buying) and record it with update_profile; confirm with a choice if unsure.',
        )
        ..writeln();
    }

    buffer
      ..writeln('# What you know about this person')
      ..writeln(profile.toPromptSummary())
      ..writeln();

    if (viewport != null) {
      buffer
        ..writeln('# Screen')
        ..writeln(viewport.describe())
        ..writeln();
    }
    return buffer.toString();
  }
}
