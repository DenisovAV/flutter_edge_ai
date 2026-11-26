// Which page runtimes take a tool response as user text, and the text it
// becomes (web_tool_responses.dart): from @litert-lm/core 0.20.0 on a
// `role: 'tool'` message is answered with no text under greedy decoding
// and on most sampler seeds (0.20.0 and 0.21.0-nightly.20261125, measured
// 2026-11-26), while `Tool <name> returned: <JSON>` as user text is
// answered.
@TestOn('vm')
library;

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

void main() {
  group('webToolResponsesAsUserText', () {
    for (final (versions, asText) in [
      (<String>{}, true), // self-hosted: the pinned version
      ({'0.20.0'}, true),
      ({'0.20.1'}, true),
      ({'0.21.0-nightly.20261125'}, true),
      ({'0.21.0'}, true),
      ({'1.0.0'}, true),
      ({'0.19.0'}, false),
      ({'0.19.9'}, false),
      ({'0.18.0'}, false),
      ({'0.19.0', '0.20.0'}, true), // two runtimes: the affected one wins
    ]) {
      test('$versions: ${asText ? 'user text' : 'a tool message'}', () {
        expect(webToolResponsesAsUserText(versions), asText);
      });
    }

    test('no page version is read as the pinned one', () {
      expect(
        webToolResponsesAsUserText({}),
        webToolResponsesAsUserText({liteRtLmWebRuntimeVersion}),
      );
    });
  });

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

    test('anything but a tool message of known parts is left as it is', () {
      expect(
        webToolResponseAsUserText({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        }),
        isNull,
      );
      expect(
        webToolResponseAsUserText({'role': 'tool', 'content': '{"a":1}'}),
        isNull,
      );
      expect(
        webToolResponseAsUserText({
          'role': 'tool',
          'content': [
            {'type': 'image', 'blob': 'AA=='},
          ],
        }),
        isNull,
      );
      expect(
        webToolResponseAsUserText({'role': 'tool', 'content': <Object?>[]}),
        isNull,
      );
    });
  });
}
