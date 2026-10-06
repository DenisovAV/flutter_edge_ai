import 'dart:async';

import '../guard/input_guard.dart';
import '../guard/narration_guard.dart';
import '../policy/policy_check.dart';
import '../profile/buyer_profile.dart';
import '../tools/finance_tool_handlers.dart';
import '../tools/tool_spec.dart';
import '../ui/ui_spec.dart';
import 'chat_driver.dart';

/// Events the UI renders from, in order of arrival.
sealed class TurnEvent {
  const TurnEvent();
}

class TextDelta extends TurnEvent {
  const TextDelta(this.text);
  final String text;
}

class ThinkingDelta extends TurnEvent {
  const ThinkingDelta(this.text);
  final String text;
}

/// A finance tool was called with a number the person never supplied; the
/// call was refused and the model told which argument to ask for.
class InputRejected extends TurnEvent {
  const InputRejected(this.tool, this.arguments);
  final String tool;
  final List<String> arguments;
}

class ToolStarted extends TurnEvent {
  const ToolStarted(this.name, this.args);
  final String name;
  final Map<String, Object?> args;
}

class ToolFinished extends TurnEvent {
  const ToolFinished(this.result);
  final ToolResult result;
}

class ProfileUpdated extends TurnEvent {
  const ProfileUpdated(this.profile);
  final BuyerProfile profile;
}

class Presented extends TurnEvent {
  const Presented(this.request, {this.result, this.automatic = false});
  final PresentRequest request;

  /// The result the component renders from; null for interaction components.
  final ToolResult? result;

  /// True when the app presented a result the model computed but never showed.
  final bool automatic;
}

class PresentRejected extends TurnEvent {
  const PresentRejected(this.errors);
  final List<String> errors;
}

/// The guard found numbers the model did not get from a tool. [replaced] is
/// true when the templated fallback was used in place of the model's text.
class GuardTripped extends TurnEvent {
  const GuardTripped(this.report, {required this.replaced});
  final GuardReport report;
  final bool replaced;
}

class PolicyFlagged extends TurnEvent {
  const PolicyFlagged(this.flags);
  final List<PolicyFlag> flags;
}

class TurnDone extends TurnEvent {
  const TurnDone({required this.narration, required this.results});
  final String narration;
  final List<ToolResult> results;
}

/// Executes tools the pipeline does not own (search, browsing). Return a map
/// for the model; throw to report an error.
typedef ExternalToolHandler =
    Future<Map<String, Object?>> Function(String name, Map<String, Object?> args);

/// One conversation's turn logic: dispatch, profile, present validation,
/// guard and policy. Pure Dart; the app supplies a [ChatDriver].
class TurnPipeline {
  TurnPipeline({
    required this.driver,
    FinanceToolHandlers? finance,
    BuyerProfile? profile,
    this.external,
    this.guard = const NarrationGuard(),
    this.inputGuard = const InputProvenanceGuard(),
    this.policy = const PolicyCheck(),
    this.regenerateOnGuardFailure = true,
  }) : finance = finance ?? FinanceToolHandlers(),
       profile = profile ?? const BuyerProfile();

  final ChatDriver driver;
  final FinanceToolHandlers finance;
  final ExternalToolHandler? external;
  final NarrationGuard guard;
  final InputProvenanceGuard inputGuard;
  final PolicyCheck policy;
  final bool regenerateOnGuardFailure;

  BuyerProfile profile;

  /// Every tool result of the conversation, by id, so `present` can refer to
  /// any of them.
  final Map<String, ToolResult> results = {};

  /// What the user typed or supplied through forms, for the guard.
  final List<Map<String, Object?>> userInputs = [];

  Stream<TurnEvent> run(String userText) {
    final controller = StreamController<TurnEvent>();
    _runInto(controller, userText).whenComplete(controller.close);
    return controller.stream;
  }

  Future<void> _runInto(StreamController<TurnEvent> out, String userText) async {
    final turnResults = <ToolResult>[];
    userInputs.add({'user_text': userText});

    Future<Map<String, Object?>> onToolCall(String name, Map<String, Object?> args) async {
      out.add(ToolStarted(name, args));
      if (finance.handles(name)) {
        final provenance = inputGuard.check(
          args: args,
          sources: [...userInputs, profile.toJson(), ...results.values.map((r) => r.result)],
        );
        if (!provenance.passed) {
          out.add(InputRejected(name, provenance.unsupported));
          return {
            'error':
                'The user did not provide ${provenance.unsupported.join(', ')}. Do not guess it: ask '
                'for it (an input_form is best), then call the tool again.',
          };
        }
        final r = finance.call(name, args);
        results[r.id] = r;
        turnResults.add(r);
        out.add(ToolFinished(r));
        // Show the number the moment it exists (DD-R18c): the model may still
        // re-present it with a different component, which replaces this card.
        final component = r.isError ? null : ComponentRegistry.defaultFor(name);
        if (component != null) {
          out.add(
            Presented(
              PresentRequest(
                component: component,
                surface: component.defaultSurface,
                resultId: r.id,
              ),
              result: r,
              automatic: true,
            ),
          );
        }
        return r.toModelJson();
      }
      switch (name) {
        case AdvisorTools.updateProfile:
          profile = profile.applyUpdate(args);
          userInputs.add(args);
          out.add(ProfileUpdated(profile));
          return {'ok': true, 'profile': profile.toPromptSummary()};
        case AdvisorTools.present:
          final resultId = args['result_id']?.toString();
          final target = resultId == null ? null : results[resultId];
          final v = PresentRequest.validate(args, resultTool: target?.tool);
          if (v.request == null) {
            out.add(PresentRejected(v.errors));
            return {'error': v.errors.join('; ')};
          }
          out.add(Presented(v.request!, result: target));
          return {'ok': true, 'shown': v.request!.component.id};
        default:
          if (external != null) {
            try {
              final r = await external!(name, args);
              final tr = ToolResult(
                id: 'x${results.length + 1}',
                tool: name,
                args: args,
                result: r,
              );
              results[tr.id] = tr;
              turnResults.add(tr);
              out.add(ToolFinished(tr));
              return tr.toModelJson();
            } catch (e) {
              return {'error': e.toString()};
            }
          }
          return {'error': 'tool "$name" is not available in this build'};
      }
    }

    var narration = stripLeakedToolCalls(await _generate(out, userText, onToolCall));

    var report = guard.check(
      narration: narration,
      sources: [...turnResults.map((r) => r.result), ...userInputs],
    );
    if (!report.passed && regenerateOnGuardFailure) {
      out.add(GuardTripped(report, replaced: false));
      final correction =
          'Your last reply contained numbers that did not come from a tool result: '
          '${report.unmatched.map((m) => m.raw).join(', ')}. Restate it using only numbers from '
          'the tool results, or no numbers at all. Do not call tools again.';
      narration = stripLeakedToolCalls(await _generate(out, correction, onToolCall, silent: true));
      report = guard.check(
        narration: narration,
        sources: [...turnResults.map((r) => r.result), ...userInputs],
      );
      if (!report.passed) {
        narration = _templated(turnResults);
        out.add(GuardTripped(report, replaced: true));
      } else {
        out.add(TextDelta(narration));
      }
    } else if (!report.passed) {
      out.add(GuardTripped(report, replaced: false));
    }

    // A model that writes "choice: option1: ..." meant to present a choice.
    // The app renders it as one (DD principle 3) and drops the prose list.
    final inline = extractInlineChoice(narration);
    if (inline != null) {
      narration = inline.remainder;
      final v = PresentRequest.validate({
        'component': 'choice',
        'props': {'question': inline.question, 'options': inline.options},
      }, resultTool: null);
      if (v.request != null) out.add(Presented(v.request!, automatic: true));
    }

    final flags = policy.check(narration);
    if (flags.isNotEmpty) out.add(PolicyFlagged(flags));

    out.add(TurnDone(narration: narration, results: turnResults));
  }

  /// Streams one generation. When [silent], text deltas are buffered rather
  /// than emitted, so a regeneration does not show two replies.
  Future<String> _generate(
    StreamController<TurnEvent> out,
    String text,
    ToolCallHandler onToolCall, {
    bool silent = false,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in driver.send(text, onToolCall: onToolCall)) {
      switch (chunk) {
        case DriverText(:final token):
          buffer.write(token);
          if (!silent) out.add(TextDelta(token));
        case DriverThinking(:final content):
          if (!silent) out.add(ThinkingDelta(content));
      }
    }
    return buffer.toString();
  }

  static String _templated(List<ToolResult> turnResults) {
    if (turnResults.isEmpty) return 'Here is what I found.';
    final names = turnResults.map((r) => r.tool.replaceAll('_', ' ')).toSet().join(', ');
    return 'Here are the results of $names. The numbers are on the card.';
  }
}

/// Small models sometimes write a tool call as text after they have started a
/// prose reply (seen with Gemma 4: an OpenAI-style `{"role":"assistant",
/// "tool_calls":[...]}` object in the middle of a sentence). The SDK may still
/// parse and run it; the text must not reach the person.
String stripLeakedToolCalls(String text) {
  var out = text;
  // Balanced-brace scan for JSON objects that mention tool_calls / function.
  var i = out.indexOf('{');
  while (i >= 0) {
    var depth = 0;
    var j = i;
    for (; j < out.length; j++) {
      if (out[j] == '{') depth++;
      if (out[j] == '}') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (j >= out.length) break;
    final candidate = out.substring(i, j + 1);
    if (candidate.contains('tool_calls') ||
        candidate.contains('"function"') ||
        candidate.contains('"name"')) {
      out = out.replaceRange(i, j + 1, ' ');
      i = out.indexOf('{', i);
    } else {
      i = out.indexOf('{', j + 1);
    }
  }
  out = out.replaceAll(RegExp(r'<\/?tool_call>|<\/?function_call>|```(?:json|tool_code)?'), ' ');
  return out.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
}

class InlineChoice {
  const InlineChoice({required this.question, required this.options, required this.remainder});
  final String question;
  final List<Map<String, String>> options;
  final String remainder;
}

/// Finds a prose-formatted option list such as
/// `choice:\n option1: fuel economy\n option2: cargo space` or
/// `1. fuel economy\n2. cargo space`, and returns it with the text that
/// remains once the list is removed. Null when there is no such list.
InlineChoice? extractInlineChoice(String text) {
  final lines = text.split('\n');
  final optionLine = RegExp(
    r'^\s*(?:option\s*\d+\s*[:.)-]|\d+\s*[.)]|[-*•])\s*(.+?)\s*$',
    caseSensitive: false,
  );
  final headerLine = RegExp(r'^\s*(?:choice|options?)\s*:\s*$', caseSensitive: false);
  var start = -1;
  var end = -1;
  final opts = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final m = optionLine.firstMatch(lines[i]);
    if (m != null) {
      if (start < 0) start = i;
      opts.add(m.group(1)!.trim());
      end = i;
    } else if (start >= 0 && lines[i].trim().isNotEmpty) {
      break;
    }
  }
  if (opts.length < 2 || opts.length > 8 || opts.any((o) => o.length > 60)) return null;
  var before = lines.sublist(0, start);
  if (before.isNotEmpty && headerLine.hasMatch(before.last)) {
    before = before.sublist(0, before.length - 1);
  }
  final after = lines.sublist(end + 1);
  final beforeText = before.join('\n').trim();
  final q = RegExp(r'([^.!?\n]*\?)\s*$').firstMatch(beforeText);
  final question = q?.group(1)?.trim() ?? 'Which matters most?';
  final remainder = [
    beforeText,
    after.join('\n'),
  ].join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return InlineChoice(
    question: question,
    options: [
      for (var i = 0; i < opts.length; i++) {'id': 'opt-${i + 1}', 'label': opts[i]},
    ],
    remainder: remainder,
  );
}
