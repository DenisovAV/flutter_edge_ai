import 'dart:async';

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
  const Presented(this.request, {this.result});
  final PresentRequest request;

  /// The result the component renders from; null for interaction components.
  final ToolResult? result;
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
    this.policy = const PolicyCheck(),
    this.regenerateOnGuardFailure = true,
  }) : finance = finance ?? FinanceToolHandlers(),
       profile = profile ?? const BuyerProfile();

  final ChatDriver driver;
  final FinanceToolHandlers finance;
  final ExternalToolHandler? external;
  final NarrationGuard guard;
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
        final r = finance.call(name, args);
        results[r.id] = r;
        turnResults.add(r);
        out.add(ToolFinished(r));
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

    var narration = await _generate(out, userText, onToolCall);

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
      narration = await _generate(out, correction, onToolCall, silent: true);
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
