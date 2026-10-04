import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_example/tools/agent_voice_responder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speaks only the final DoneEvent; tool events are not spoken', () async {
    Stream<AgentEvent> events() async* {
      yield const SkillLoadEvent('weather');
      yield const ToolCallEvent(toolName: 'runSkill', args: {});
      yield const DoneEvent("It's 22°C.");
    }

    final spoken = await agentEventsToSpeech(events(), fallback: 'fb').toList();
    expect(spoken, ["It's 22°C."]);
  });

  test('MaxIterationsEvent -> fallback (no dead silence)', () async {
    Stream<AgentEvent> events() async* {
      yield const MaxIterationsEvent(10);
    }

    final spoken = await agentEventsToSpeech(
      events(),
      fallback: 'nope',
    ).toList();
    expect(spoken, ['nope']);
  });
}
