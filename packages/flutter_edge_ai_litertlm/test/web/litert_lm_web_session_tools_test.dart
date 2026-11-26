// A tool response on a web session opened without tools goes as user text,
// as natively and as for a model whose tool calling runs in Dart: the
// runtime's Conversation refuses a tool message when it declares no tools.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_session_tools_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'web_session_fixture.dart';

/// A Conversation that records what it was sent and answers with an empty
/// reply.
({JSObject conversation, List<JSAny?> sent}) _stubConversation() {
  final sent = <JSAny?>[];
  final done = JSObject()..['done'] = true.toJS;
  final iterator = JSObject()
    ..['next'] = (() => Future<JSObject>.value(done).toJS).toJS;
  final conversation = JSObject()
    ..['sendMessageStreaming'] = ((JSAny? message) {
      sent.add(message);
      return iterator;
    }).toJS
    ..['cancel'] = (() {}).toJS
    ..['getHistory'] = (() {
      final last = sent.last;
      final message = last.isA<JSString>()
          ? ({'role': 'user', 'content': (last as JSString).toDart}.jsify())
          : last;
      final reply = {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': ''},
        ],
      }.jsify();
      return Future<JSArray<JSAny?>>.value([message, reply].toJS).toJS;
    }).toJS
    ..['delete'] = (() => Future<void>.value().toJS).toJS;
  return (conversation: conversation, sent: sent);
}

void main() {
  for (final modelType in [ModelType.gemma4, ModelType.functionGemma]) {
    test('$modelType: a tool response on a session without tools is sent as '
        'user text', () async {
      final stub = _stubConversation();
      final session = webSessionOver(stub.conversation, modelType: modelType);
      await session.addQueryChunk(
        Message.toolResponse(toolName: 'multiply', response: {'result': 7}),
      );
      expect(await session.getResponse(), '');
      final sent = jsonEncode(stub.sent.single.dartify());
      expect(sent, contains('<tool_response>'));
      expect(sent, contains('multiply'));
      expect(sent, isNot(contains('"role":"tool"')));
    });
  }
}
