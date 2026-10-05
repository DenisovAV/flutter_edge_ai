import 'package:flutter_gemma_agent/flutter_gemma_agent.dart'
    show AgentEvent, AgentSession, DoneEvent, MaxIterationsEvent;
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart'
    show VoiceResponder;

const _kFallback = "Sorry, I couldn't finish that.";

/// Map an agent event stream to spoken text: speak only the final answer
/// ([DoneEvent]); substitute [fallback] for a [MaxIterationsEvent]; ignore
/// tool/skill progress events (a UI would show those separately).
///
/// Exposed (not private) so `agent_voice_responder_test.dart` can drive it
/// directly with a fake [AgentEvent] stream, without building a real
/// [AgentSession]. Not annotated `@visibleForTesting` to avoid adding a
/// `meta` dependency to the example package for this alone.
Stream<String> agentEventsToSpeech(
  Stream<AgentEvent> events, {
  String fallback = _kFallback,
}) async* {
  await for (final e in events) {
    if (e is DoneEvent) {
      if (e.text.isNotEmpty) yield e.text;
    } else if (e is MaxIterationsEvent) {
      yield fallback;
    }
  }
}

/// A [VoiceResponder] backed by the full agent (skills / MCP / tools). Drop it
/// into `VoiceSession.custom(responder: ...)`. Lives in the app, not in
/// flutter_gemma_speech, so speech never depends on flutter_gemma_agent.
VoiceResponder agentVoiceResponder(
  AgentSession agent, {
  String maxIterationsFallback = _kFallback,
}) {
  // Cancellation is PER-TURN: each respond() creates its own token and stop()
  // cancels only the currently-active one. A single shared boolean that
  // respond() resets to false would UN-cancel a prior turn's detached
  // (drain-timeout) agent loop, letting it resume tool calls on this same
  // chat concurrently with the new turn.
  _CancelToken? activeToken;
  return VoiceResponder(
    respond: (userText) {
      final token = _CancelToken();
      activeToken = token;
      // isCancelled (flutter_gemma_agent 0.2.0, Task 3a) makes barge-in halt
      // the agent loop before the next tool, not just mute the speech.
      return agentEventsToSpeech(
        agent.ask(userText, isCancelled: () => token.cancelled),
        fallback: maxIterationsFallback,
      );
    },
    stop: () async {
      activeToken?.cancel();
      await agent.chat.stopGeneration();
    },
  );
}

/// Per-turn cancellation token — an enforced one-way latch: [cancelled] is
/// read-only and [cancel] can only ever set it true (never reset), so a later
/// turn (with its OWN token) cannot un-cancel a prior turn's still-running
/// detached loop.
class _CancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}
