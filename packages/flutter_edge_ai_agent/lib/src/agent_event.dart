import 'skill.dart';
import 'skill_result.dart';

/// A progress event emitted by the [AgentLoop] as it drives a turn, so the UI
/// can show a step-by-step panel (mirrors Gallery's `SkillProgressAgentAction`)
/// and render inline image / webview / widget skill results.
///
/// Sealed so the UI can exhaustively `switch` on the variant.
sealed class AgentEvent {
  const AgentEvent();
}

/// The model produced a (non-tool) tool-call request to load a skill's
/// instructions. Emitted before [loadSkill] runs so the UI can show
/// "Loading skill X".
class SkillLoadEvent extends AgentEvent {
  const SkillLoadEvent(this.skillName, {this.found = true});

  /// The skill the model asked to load.
  final String skillName;

  /// Whether a skill with this name was found in the registry.
  final bool found;

  @override
  String toString() => 'SkillLoadEvent($skillName, found: $found)';
}

/// The model asked to run a skill / intent / MCP tool. Emitted before the
/// matching [SkillExecutor] runs so the UI can show "Running X".
class ToolCallEvent extends AgentEvent {
  const ToolCallEvent({required this.toolName, required this.args, this.skill});

  /// The agent tool the model called (`runSkill` / `runIntent` / `runMcp`).
  final String toolName;

  /// The arguments the model passed to the tool.
  final Map<String, dynamic> args;

  /// The resolved [Skill] when the call targeted one (skill executors); null
  /// for tool-only calls that don't map to a registered skill.
  final Skill? skill;

  @override
  String toString() => 'ToolCallEvent($toolName, args: $args)';
}

/// A skill / intent / MCP tool finished. Carries the [SkillResult] so the UI can
/// render an inline image / webview / native widget alongside the text fed back
/// to the model.
class ToolResultEvent extends AgentEvent {
  const ToolResultEvent({required this.toolName, required this.result});

  /// The tool that produced [result].
  final String toolName;

  /// The structured result the executor returned.
  final SkillResult result;

  @override
  String toString() => 'ToolResultEvent($toolName, $result)';
}

/// A streamed text token of the model's final (non-tool) answer.
class TextChunkEvent extends AgentEvent {
  const TextChunkEvent(this.text);

  final String text;

  @override
  String toString() => 'TextChunkEvent("$text")';
}

/// The loop finished: the model produced a plain text answer (no more tool
/// calls). [text] is the full accumulated final answer.
///
/// An [EmptyAnswerEvent] is a [DoneEvent] too: match it first to tell an
/// answer the model never gave apart from a short one.
class DoneEvent extends AgentEvent {
  const DoneEvent(this.text);

  /// The model's final answer.
  final String text;

  @override
  String toString() => 'DoneEvent("$text")';
}

/// The generation that ended the turn produced no text right after a
/// successful `loadSkill`, so the loop asks again: it adds [nudge] to the chat
/// as a user message and generates once more. Emitted before the nudge is
/// sent, at most [AgentLoop.emptyAfterSkillRetries] times per turn.
///
/// The nudge stays in the chat's history like any user message; an app that
/// keeps its own copy of the history should add it there too.
class EmptyAnswerRetryEvent extends AgentEvent {
  const EmptyAnswerRetryEvent({
    required this.skillName,
    required this.nudge,
    required this.attempt,
  });

  /// The skill whose `loadSkill` call came right before the empty generation.
  final String skillName;

  /// The user message the loop adds to the chat.
  final String nudge;

  /// 1 for the turn's first retry, 2 for its second, and so on.
  final int attempt;

  @override
  String toString() =>
      'EmptyAnswerRetryEvent($skillName, attempt: $attempt, nudge: "$nudge")';
}

/// The turn ended with no text right after a successful `loadSkill`, and no
/// retry was left: the turn used [AgentLoop.emptyAfterSkillRetries] (or it is
/// 0), or [AgentLoop.maxIterations] left no generation for one.
///
/// A [DoneEvent] with an empty [text], so code written for [DoneEvent] keeps
/// working; a `switch` that wants to say "the model gave no answer" puts this
/// case before `DoneEvent`.
class EmptyAnswerEvent extends DoneEvent {
  const EmptyAnswerEvent(this.skillName) : super('');

  /// The skill whose `loadSkill` call came right before the empty generation.
  final String skillName;

  @override
  String toString() => 'EmptyAnswerEvent($skillName)';
}

/// The loop hit its [AgentLoop.maxIterations] guard without the model settling
/// on a text answer — surfaced so the UI can tell the user instead of looping
/// forever.
class MaxIterationsEvent extends AgentEvent {
  const MaxIterationsEvent(this.iterations);

  /// The iteration cap that was reached.
  final int iterations;

  @override
  String toString() => 'MaxIterationsEvent($iterations)';
}

/// An error surfaced while driving the loop (executor threw, no executor could
/// handle a call, …). The loop feeds an error tool-response back to the model so
/// it can recover; this event lets the UI show it too.
class AgentErrorEvent extends AgentEvent {
  const AgentErrorEvent(this.message, {this.toolName});

  final String message;

  /// The tool whose execution failed, if the error is tied to one.
  final String? toolName;

  @override
  String toString() => 'AgentErrorEvent($message, toolName: $toolName)';
}
