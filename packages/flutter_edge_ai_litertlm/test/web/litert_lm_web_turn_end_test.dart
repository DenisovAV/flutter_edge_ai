// How a web `.litertlm` turn ends, as core's chat reads it: a stop is
// TurnEnd.stopped and a close the consumer did not ask for TurnEnd.closed,
// each with the text generated so far and no error.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_lm_web_turn_end_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web_inference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

/// A conversation that streams one chunk, then waits until it is cancelled
/// and ends.
LiteRtLmConversation _conversation() {
  final cancelled = Completer<void>();
  var step = 0;
  final iterator = JSObject()
    ..['next'] = (() {
      if (step++ == 0) {
        final value = {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Par'},
          ],
        }.jsify();
        return Future<JSObject>.value(
          JSObject()
            ..['done'] = false.toJS
            ..['value'] = value,
        ).toJS;
      }
      return cancelled.future
          .then((_) => JSObject()..['done'] = true.toJS)
          .toJS;
    }).toJS;
  return (JSObject()
        ..['sendMessageStreaming'] = ((JSAny? message) => iterator).toJS
        ..['cancel'] = (() {
          if (!cancelled.isCompleted) cancelled.complete();
        }).toJS)
      as LiteRtLmConversation;
}

LiteRtLmWebSession _session() => LiteRtLmWebSession(
  conversation: _conversation(),
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
  generationMutex: Mutex(),
  onClose: () {},
);

// ignore: invalid_use_of_protected_member
EngineTurn _turn(InferenceModelSession session) => session.startTurn();

void main() {
  for (final (how, expected) in [
    ('stop', TurnEnd.stopped),
    ('close', TurnEnd.closed),
  ]) {
    test('a $how mid-turn is $expected, with the partial text', () async {
      final session = _session();
      await session.addQueryChunk(const Message(text: 'Hi', isUser: true));
      final turn = _turn(session);
      final first = Completer<void>();
      final text = <String>[];
      final done = turn.text.forEach((chunk) {
        text.add(chunk);
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      if (how == 'stop') {
        await session.stopGeneration();
      } else {
        await session.close();
      }
      await done;
      expect(text, ['Par']);
      expect(await turn.end, expected);
    });
  }
}
