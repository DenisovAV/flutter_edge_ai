import '../profile/buyer_profile.dart';
import '../ui/ui_spec.dart';

/// What the model is told about the canvas each turn (DD-R10).
class ViewportDescriptor {
  /// Creates a descriptor; sizes are in density-independent pixels.
  const ViewportDescriptor({
    required this.widthDp,
    required this.heightDp,
    this.keyboardVisible = false,
    this.posture = 'phone',
  });

  /// Canvas width in density-independent pixels.
  final double widthDp;

  /// Canvas height in density-independent pixels.
  final double heightDp;

  /// True when the soft keyboard covers part of the canvas.
  final bool keyboardVisible;

  /// `phone`, `wide` (tablet or unfolded foldable), or `folded`.
  final String posture;

  /// One line for the prompt, such as `390x844 dp, phone, keyboard down`.
  String describe() =>
      '${widthDp.round()}x${heightDp.round()} dp, $posture, keyboard ${keyboardVisible ? 'up' : 'down'}';
}

// The three sections below are fixed in code rather than loaded as assets:
// they state the contract between the model and the pipeline (numbers come
// from tools, options come through present, cards follow tool results). An
// edit to the prompt assets must not be able to loosen what the guards
// enforce, so these travel with the code that enforces them.

/// The rule the narration guard and the input guard enforce.
const String _numbersSection =
    '# Numbers\n'
    'Never compute or guess a dollar amount, rate, payment or percentage: call a tool and repeat '
    'only what it returns. Missing an input? Ask with an input_form, do not assume.';

/// How a reply is shaped; the prose-list rule is what `extractInlineChoice`
/// repairs when it is broken.
const String _replyingSection =
    '# Replying\n'
    'If a tool is needed, call it first; the card appears for the person while you work. '
    'When the person names a budget, a body style or a model, call find_vehicles. '
    'Then reply in under 80 words. Plain text, no Markdown. Never write options as a list in '
    'prose: offer them with present(choice).';

/// How results and questions reach the screen; the component list follows
/// it from the registry.
const String _screenSection =
    '# Screen\n'
    'After a tool returns, call present(component, result_id) so the numbers are shown as a card; '
    'then one or two sentences at most. To ask something with a few possible answers, or to '
    'collect numbers, call present with choice/multi_choice/input_form instead of asking in prose. '
    'One structured prompt per turn.';

/// Assembles the system prompt from editable text sections plus the fixed
/// contract sections, the component vocabulary and the live situation
/// (profile, viewport). The editable sections are data (Markdown assets in
/// the app, TQ46), not code. Tools are not described here: they reach the
/// model through the SDK's tool registration, so listing them again would
/// only spend context.
class SystemPromptBuilder {
  /// Creates a builder from the three editable text sections.
  const SystemPromptBuilder({
    required this.persona,
    required this.policy,
    required this.modeGuidance,
  });

  /// Who Motormind is and how it behaves.
  final String persona;

  /// The non-salesperson rules.
  final String policy;

  /// Tone and emphasis per shopping mode.
  final Map<ShoppingMode, String> modeGuidance;

  /// Builds the prompt for the next turn: the persona, the policy, the
  /// fixed number, replying and screen sections, the component vocabulary
  /// from [ComponentRegistry.describeForPrompt], guidance for the current
  /// [ShoppingMode], the profile summary and, when given, the [viewport].
  String build({required BuyerProfile profile, ViewportDescriptor? viewport}) {
    final mode = profile.mode;
    final buffer = StringBuffer()
      ..writeln(persona.trim())
      ..writeln()
      ..writeln('# Rules')
      ..writeln(policy.trim())
      ..writeln()
      ..writeln(_numbersSection)
      ..writeln()
      ..writeln(_replyingSection)
      ..writeln()
      ..writeln(_screenSection)
      ..writeln('Components:')
      ..writeln(ComponentRegistry.describeForPrompt())
      ..writeln();

    final guidance = mode == null ? null : modeGuidance[mode];
    if (mode != null && guidance != null) {
      buffer
        ..writeln('# Current shopping mode: ${mode.name}')
        ..writeln(guidance.trim())
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
