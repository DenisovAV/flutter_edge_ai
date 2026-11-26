// The user text a tool message becomes on the web (web_tool_responses.dart):
// `@litert-lm/core` answers a `role: 'tool'` message with no text on most
// sampler seeds (0.20.0 and 0.21.0-nightly.20261125, measured 2026-11-26),
// while `Tool <name> returned: <JSON>` as user text is answered.
@TestOn('vm')
library;

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

void main() {
  group('webToolResponseAsUserText', () {
    test('one result is the text variant E answered with', () {
      expect(
        webToolResponseAsUserText({
          'role': 'tool',
          'content': [
            {
              'type': 'tool_response',
              'name': 'change_color',
              'response': {'status': 'success', 'applied_color': 'purple'},
            },
          ],
        }),
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  'Tool change_color returned: '
                  '{"status":"success","applied_color":"purple"}',
            },
          ],
        },
      );
    });

    test('a call id is kept, results go one per line in order, a text '
        'part as it is, a string response quoted', () {
      final message = webToolResponseAsUserText({
        'role': 'tool',
        'content': [
          {
            'type': 'tool_response',
            'name': 'weather',
            'response': {'temp': 25},
            'id': 'call_1',
          },
          {'type': 'text', 'text': 'note'},
          {
            'type': 'tool_response',
            'name': 'time',
            'response': 'Error: offline',
          },
        ],
      });
      expect((message!['content']! as List).single, {
        'type': 'text',
        'text':
            'Tool weather (call call_1) returned: {"temp":25}\n'
            'note\n'
            'Tool time returned: "Error: offline"',
      });
    });

    test('a message that is no tool response is left as it is', () {
      expect(
        webToolResponseAsUserText({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        }),
        isNull,
      );
    });

    test('media beside a result stay, in order, in the same user message', () {
      expect(
        webToolResponseAsUserText({
          'role': 'tool',
          'content': [
            {'type': 'text', 'text': 'before'},
            {
              'type': 'tool_response',
              'name': 'weather',
              'response': {'temp': 25},
            },
            {'type': 'image', 'blob': 'AA=='},
            {'type': 'audio', 'blob': 'AQ=='},
            {'type': 'tool_response', 'name': 'time', 'response': '12:00'},
          ],
        }),
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': 'before\nTool weather returned: {"temp":25}',
            },
            {'type': 'image', 'blob': 'AA=='},
            {'type': 'audio', 'blob': 'AQ=='},
            {'type': 'text', 'text': 'Tool time returned: "12:00"'},
          ],
        },
      );
    });

    test('a result in a message of another role is converted too', () {
      expect(
        webToolResponseAsUserText({
          'role': 'user',
          'content': [
            {
              'type': 'tool_response',
              'name': 'weather',
              'response': {'temp': 25},
            },
          ],
        }),
        userText('Tool weather returned: {"temp":25}'),
      );
    });

    test('a result without a response is written as null', () {
      expect(
        webToolResponseAsUserText({
          'role': 'tool',
          'content': [
            {'type': 'tool_response', 'name': 'ping'},
          ],
        }),
        userText('Tool ping returned: null'),
      );
    });

    test('a tool message never stays one', () {
      expect(
        webToolResponseAsUserText({'role': 'tool', 'content': '{"a":1}'}),
        {'role': 'user', 'content': '{"a":1}'},
      );
      expect(
        webToolResponseAsUserText({'role': 'tool', 'content': <Object?>[]}),
        {'role': 'user', 'content': <Object?>[]},
      );
      expect(webToolResponseAsUserText({'role': 'tool'}), {
        'role': 'user',
        'content': <Object?>[],
      });
      expect(
        webToolResponseAsUserText({
          'role': 'tool',
          'content': [
            {'type': 'image', 'blob': 'AA=='},
          ],
        }),
        {
          'role': 'user',
          'content': [
            {'type': 'image', 'blob': 'AA=='},
          ],
        },
      );
    });
  });
}

Map<String, Object?> userText(String text) => {
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
};
