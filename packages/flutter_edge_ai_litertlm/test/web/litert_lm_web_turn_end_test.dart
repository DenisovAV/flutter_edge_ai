// How a web `.litertlm` turn ends, as core's chat reads it: a stop is
// TurnEnd.stopped and a close the consumer did not ask for TurnEnd.closed,
// each with the text generated so far and no error.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_turn_end_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/web_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_web.dart' show WebConversationHandle;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import 'web_session_fixture.dart';

/// A conversation that streams one chunk, then waits until it is cancelled
/// and ends.
JSObject _conversation() {
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
    }).toJS
    ..['delete'] = (() => Future<void>.value().toJS).toJS);
}

LiteRtLmWebSession _session() => webSessionOver(_conversation());

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

  test('a model closed mid-turn, its session left open, is TurnEnd.closed '
      'with the partial text', () async {
    late WebConversationHandle handle;
    final session = webSessionOver(
      _conversation(),
      onHandle: (h) => handle = h,
    );
    await session.addQueryChunk(const Message(text: 'Hi', isUser: true));
    final turn = _turn(session);
    final first = Completer<void>();
    final text = <String>[];
    final done = turn.text.forEach((chunk) {
      text.add(chunk);
      if (!first.isCompleted) first.complete();
    });
    await first.future;

    // What the model's close does to each conversation it opened.
    await handle.close();
    await done;

    expect(text, ['Par']);
    expect(await turn.end, TurnEnd.closed);
  });

  test('a turn the runtime fails reaches core as a plain Exception with the '
      'runtime\'s text, as natively', () async {
    final iterator = JSObject()
      ..['next'] = (() => Future<JSObject>.error(
        StateError('Task failed with state: 7'),
      ).toJS).toJS;
    final conversation = JSObject()
      ..['sendMessageStreaming'] = ((JSAny? message) => iterator).toJS
      ..['cancel'] = (() {}).toJS
      ..['getTokenCount'] = (() => Future<JSNumber>.value(1.toJS).toJS).toJS
      ..['delete'] = (() => Future<void>.value().toJS).toJS;
    final session = webSessionOver(conversation);
    await session.addQueryChunk(const Message(text: 'Hi', isUser: true));

    await expectLater(
      _turn(session).text.toList(),
      throwsA(
        allOf(
          isNot(isA<lm.LiteRtLmException>()),
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('Task failed with state: 7'),
          ),
        ),
      ),
    );
  });
}
