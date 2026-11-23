// The assistant message a rebuilt conversation replays for a reply
// (lib/src/runtime/tool_calls.dart), shared by the native and web handles.
import 'package:litertlm_dart/internal_io.dart'
    show assistantTurnMessage, nativeToolCalls;
import 'package:test/test.dart';

void main() {
  test('a reply with converted tool calls is replayed as its calls', () {
    expect(
      assistantTurnMessage(
        nativeToolCalls,
        '',
        '{"role":"assistant","tool_calls":[{"type":"function",'
            '"function":{"name":"f","arguments":{"n":1}}}]}',
      ),
      {
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'f',
              'arguments': {'n': 1},
            },
          },
        ],
      },
    );
  });

  test('a reader that throws leaves the reply as its text', () {
    expect(
      assistantTurnMessage((_) => throw StateError('bad reader'), 'Hi', '{}'),
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Hi'},
        ],
      },
    );
  });
}
