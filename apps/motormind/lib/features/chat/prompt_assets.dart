import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The system prompt's parts, kept as Markdown assets so wording changes are
/// reviewable diffs and not code: the persona, the policy, and one
/// section per shopping mode.
final promptAssetsProvider = FutureProvider<SystemPromptBuilder>((ref) async {
  final persona = await rootBundle.loadString('assets/prompts/persona.md');
  final policy = await rootBundle.loadString('assets/prompts/policy.md');
  final modes = await rootBundle.loadString('assets/prompts/modes.md');
  return SystemPromptBuilder(persona: persona, policy: policy, modeGuidance: parseModes(modes));
});

/// Splits `modes.md` into one entry per `# <mode>` heading. Headings that are
/// not a [ShoppingMode] name are ignored, so the file can carry notes.
Map<ShoppingMode, String> parseModes(String markdown) {
  final out = <ShoppingMode, String>{};
  ShoppingMode? current;
  final buffer = StringBuffer();
  void flush() {
    final mode = current;
    if (mode != null) out[mode] = buffer.toString().trim();
    buffer.clear();
  }

  for (final line in markdown.split('\n')) {
    if (line.startsWith('# ')) {
      flush();
      final name = line.substring(2).trim();
      current = ShoppingMode.values.where((m) => m.name == name).firstOrNull;
    } else {
      buffer.writeln(line);
    }
  }
  flush();
  return out;
}
