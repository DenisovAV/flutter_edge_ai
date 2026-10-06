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
        'Never compute or guess a dollar amount, rate, payment or percentage: call a tool and repeat '
        'only what it returns. Missing an input? Ask with an input_form, do not assume.',
      )
      ..writeln()
      ..writeln('# Replying')
      ..writeln(
        'If a tool is needed, call it first; the card appears for the person while you work. '
        'Then reply in under 80 words. Plain text, no Markdown.',
      )
      ..writeln()
      ..writeln('# Screen')
      ..writeln(
        'After a tool returns, call present(component, result_id) so the numbers are shown as a card; '
        'then one or two sentences at most. To ask something with a few possible answers, or to '
        'collect numbers, call present with choice/multi_choice/input_form instead of asking in prose. '
        'One structured prompt per turn.',
      )
      ..writeln(
        'Components: ${ComponentRegistry.all.map((c) => '${c.id} (${c.description})').join('; ')}',
      )
      ..writeln();

    if (mode != null && modeGuidance[mode] != null) {
      buffer
        ..writeln('# Current shopping mode: ${mode.name}')
        ..writeln(modeGuidance[mode]!.trim())
        ..writeln();
    } else {
      buffer
        ..writeln(
          '# Shopping mode: unknown. Infer it (browsing/dreaming/practical/buying) and record it with update_profile.',
        )
        ..writeln();
    }

    buffer
      ..writeln('# Known about this person: ${profile.toPromptSummary()}')
      ..writeln();

    if (viewport != null) {
      buffer
        ..writeln('# Viewport: ${viewport.describe()}')
        ..writeln();
    }
    return buffer.toString();
  }
}
