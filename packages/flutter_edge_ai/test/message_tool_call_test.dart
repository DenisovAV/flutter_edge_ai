import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Message.toolCall', () {
    test(
      'builds the canonical text from calls, an id only where one exists',
      () {
        final message = Message.toolCall(
          calls: const [
            FunctionCallResponse(
              name: 'search',
              args: {'q': 'a'},
              id: 'call_1',
            ),
            FunctionCallResponse(name: 'clock', args: {}),
          ],
        );

        expect(message.type, MessageType.toolCall);
        expect(message.isUser, isFalse);
        expect(jsonDecode(message.text), {
          'tool_calls': [
            {
              'id': 'call_1',
              'name': 'search',
              'arguments': {'q': 'a'},
            },
            {'name': 'clock', 'arguments': <String, dynamic>{}},
          ],
        });
        expect(message.toolCalls, hasLength(2));
        expect(
          () => message.toolCalls.add(
            const FunctionCallResponse(name: 'x', args: {}),
          ),
          throwsUnsupportedError,
        );
      },
    );

    test('keeps the given text verbatim beside the calls', () {
      const raw =
          '<tool_call>{"name":"search","arguments":{"q":"a"}}</tool_call>';
      final message = Message.toolCall(
        text: raw,
        calls: const [
          FunctionCallResponse(name: 'search', args: {'q': 'a'}),
        ],
      );

      expect(message.text, raw);
      expect(message.toolCalls.single.name, 'search');
    });

    test('text alone still works and carries no calls', () {
      final message = Message.toolCall(text: '{"name":"search"}');

      expect(message.text, '{"name":"search"}');
      expect(message.toolCalls, isEmpty);
    });

    test('refuses neither text nor calls', () {
      expect(() => Message.toolCall(), throwsArgumentError);
    });
  });

  test('Message.toolResponse carries the id of the call it answers', () {
    final answered = Message.toolResponse(
      toolName: 'search',
      response: {'ok': true},
      toolCallId: 'call_1',
    );
    final byName = Message.toolResponse(
      toolName: 'search',
      response: {'ok': true},
    );

    expect(answered.toolCallId, 'call_1');
    expect(answered.type, MessageType.toolResponse);
    expect(byName.toolCallId, isNull);
    expect(answered, isNot(byName));
  });

  test('equality, hashCode and copyWith cover the new fields', () {
    Message call(Map<String, dynamic> args) => Message.toolCall(
      text: 'same text',
      calls: [FunctionCallResponse(name: 'search', args: args, id: 'a')],
    );

    final a = call({
      'q': 'a',
      'filters': [1, 2],
    });
    final b = call({
      'q': 'a',
      'filters': [1, 2],
    });
    final c = call({
      'q': 'a',
      'filters': [2, 1],
    });

    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));

    final copied = Message.toolResponse(
      toolName: 't',
      response: {},
      toolCallId: 'x',
    ).copyWith(text: '{"v":1}');
    expect(copied.toolCallId, 'x');
    expect(a.copyWith(isUser: false).toolCalls, a.toolCalls);
  });

  group('FunctionCallResponse', () {
    test('is equal by name, id and arguments, nested included', () {
      const a = FunctionCallResponse(
        name: 'f',
        args: {
          'm': {'k': 1},
          'l': [1],
        },
        id: '1',
      );
      const b = FunctionCallResponse(
        name: 'f',
        args: {
          'l': [1],
          'm': {'k': 1},
        },
        id: '1',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const FunctionCallResponse(
            name: 'f',
            args: {
              'm': {'k': 1},
              'l': [1],
            },
            id: '2',
          ),
        ),
      );
      expect(
        a,
        isNot(
          const FunctionCallResponse(
            name: 'f',
            args: {
              'm': {'k': 2},
              'l': [1],
            },
            id: '1',
          ),
        ),
      );
    });
  });
}
