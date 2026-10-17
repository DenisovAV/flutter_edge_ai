import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A conversation that answers with scripted text chunks, one turn at a time,
/// and can be held open mid-turn so a test can stop it there.
class _Conversation implements ConversationHandle {
  _Conversation(this.name, {this.seed});

  final String name;

  /// The `messages_json` this conversation was opened with.
  final String? seed;

  final sent = <String>[];
  var cancels = 0;
  var closed = false;

  /// When set, the next turn emits its first chunk and then waits on this
  /// until the test completes it — a generation in flight.
  Completer<void>? hold;

  /// When set, the next turn fails with it after its first chunk.
  Object? failWith;

  Stream<String> _reply(String input) async* {
    sent.add(input);
    final cancelsBefore = cancels;
    yield 'Hello';
    final gate = hold;
    hold = null;
    if (gate != null) await gate.future;
    // Like native: a cancelled generation ends without another chunk.
    if (cancels > cancelsBefore) return;
    final error = failWith;
    failWith = null;
    if (error != null) throw error;
    yield ' there.';
  }

  @override
  Future<int?> tokenCount(String text) async => null;

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _reply(text);

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _reply(text);

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) => _reply(messageJson);

  @override
  void cancelGeneration() => cancels++;

  /// What [rewindStoppedTurn] answers: a [StoppedTurnRewind], or anything else
  /// to throw. Unsupported by default, like a libLiteRtLm without the rewind.
  Object rewindOutcome = StoppedTurnRewind.unsupported;

  /// The partial replies [rewindStoppedTurn] was given.
  final rewinds = <Map<String, Object?>>[];

  /// When set, a rewind waits on it — a native prefill in flight.
  Completer<void>? rewindGate;

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?> partialReply,
  ) async {
    rewinds.add(partialReply);
    await rewindGate?.future;
    final outcome = rewindOutcome;
    if (outcome is StoppedTurnRewind) return outcome;
    throw outcome;
  }

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  void close() => closed = true;
}

void main() {
  late _Conversation first;
  late List<_Conversation> reopened;
  late RecoveringConversationHandle handle;

  /// When set, a rebuild waits on it before the new conversation exists — a
  /// native create in flight.
  Completer<void>? reopenGate;

  setUp(() {
    first = _Conversation('first');
    reopened = [];
    reopenGate = null;
    handle = RecoveringConversationHandle(
      first,
      reopen: (messagesJson) async {
        await reopenGate?.future;
        final c = _Conversation(
          'rebuilt ${reopened.length}',
          seed: messagesJson,
        );
        reopened.add(c);
        return c;
      },
    );
  });

  /// Runs one turn and stops it after its first chunk.
  Future<String> stopMidTurn(String text, _Conversation live) async {
    final gate = live.hold = Completer<void>();
    final out = StringBuffer();
    await for (final chunk in handle.chat(text)) {
      out.write(chunk);
      if (!gate.isCompleted) {
        handle.cancelGeneration();
        gate.complete();
      }
    }
    return out.toString();
  }

  test('turns run on the same conversation while nothing is stopped', () async {
    expect(await handle.chat('one').join(), 'Hello there.');
    expect(await handle.chat('two').join(), 'Hello there.');
    // Dart cancels a subscription on `done`; a cancel after a finished turn
    // is not a stop.
    handle.cancelGeneration();
    expect(await handle.chat('three').join(), 'Hello there.');
    expect(first.sent, ['one', 'two', 'three']);
    expect(reopened, isEmpty);
  });

  test('the turn after a stop runs on a rebuilt conversation that '
      'replays the history, partial reply included', () async {
    expect(await handle.chat('one').join(), 'Hello there.');
    await stopMidTurn('two', first);

    expect(await handle.chat('three').join(), 'Hello there.');
    expect(first.closed, isTrue, reason: 'one live conversation per engine');
    expect(reopened, hasLength(1));
    expect(reopened.single.sent, ['three']);

    final seed = jsonDecode(reopened.single.seed!) as List<dynamic>;
    String textOf(Map<String, dynamic> m) =>
        (m['content'] as List).single['text'] as String;
    expect(
      [for (final m in seed) m['role']],
      ['user', 'assistant', 'user', 'assistant'],
    );
    expect(textOf(seed[2] as Map<String, dynamic>), 'two');
    // The stopped turn's reply is what the model had written when stopped.
    expect(textOf(seed[3] as Map<String, dynamic>), 'Hello');
  });

  test('a rebuilt conversation is kept until the next stop', () async {
    await stopMidTurn('one', first);
    await handle.chat('two').join();
    await handle.chat('three').join();
    expect(reopened, hasLength(1));
    expect(reopened.single.sent, ['two', 'three']);
  });

  test('abandoning the stream mid-turn counts as a stop', () async {
    final gate = first.hold = Completer<void>();
    final sub = handle.chat('one').listen(null);
    await pumpEventQueue();
    // Cancelling waits for the generator to reach its `finally`, and it is
    // parked on the gate — so open the gate without awaiting the cancel first.
    final cancelled = sub.cancel();
    gate.complete();
    await cancelled;

    await handle.chat('two').join();
    expect(reopened, hasLength(1));
  });

  test('a failed turn is not a stop: no rebuild replays it into the same '
      'failure', () async {
    first.failWith = StateError('native error');
    await expectLater(handle.chat('one').join(), throwsStateError);
    await handle.chat('two').join();
    expect(reopened, isEmpty);
    expect(first.sent, ['one', 'two']);
  });

  test(
    'tool results sent after a stop go to the rebuilt conversation',
    () async {
      await stopMidTurn('one', first);
      const toolResult = '{"role":"tool","content":[]}';
      await handle.chatRawMessage(toolResult).join();
      expect(reopened.single.sent, [toolResult]);
    },
  );

  test('a turn started before the stopped one has wound down still '
      'replays it', () async {
    // VoiceSession can do this: after a bounded drain it detaches the
    // stopped stream and starts the next turn while that stream is still
    // finishing.
    final gate = first.hold = Completer<void>();
    final stopped = handle.chat('one').join();
    await pumpEventQueue();
    handle.cancelGeneration();

    final next = handle.chat('two').join();
    await pumpEventQueue();
    gate.complete();
    await stopped;
    await next;

    final seed = jsonDecode(reopened.single.seed!) as List<dynamic>;
    expect(
      [for (final m in seed) (m['content'] as List).single['text']],
      ['one', 'Hello'],
      reason: 'the stopped exchange must be in the replayed history',
    );
  });

  test('a stop that lands while the conversation is being rebuilt stops '
      'the turn before it reaches the model', () async {
    await stopMidTurn('one', first);

    final gate = reopenGate = Completer<void>();
    final pending = handle.chat('two').join();
    await pumpEventQueue();
    handle.cancelGeneration();
    gate.complete();

    expect(await pending, isEmpty);
    expect(reopened.single.sent, isEmpty, reason: 'nothing was sent');
    // Nothing was generated on the new conversation, so nothing damaged it:
    // the next turn runs there without another rebuild.
    expect(await handle.chat('three').join(), 'Hello there.');
    expect(reopened, hasLength(1));
    expect(reopened.single.sent, ['three']);
  });

  test('a stopped turn whose stream is paused, not cancelled, does not '
      'block the next turn forever', () async {
    handle = RecoveringConversationHandle(
      first,
      reopen: (messagesJson) async {
        final c = _Conversation('rebuilt', seed: messagesJson);
        reopened.add(c);
        return c;
      },
      windDownTimeout: const Duration(milliseconds: 100),
    );
    // Paused before its first chunk is delivered, so the turn is parked on
    // that `yield` and cannot reach its `finally` until someone resumes it.
    final sub = handle.chat('one').listen(null)..pause();
    await pumpEventQueue();
    handle.cancelGeneration();

    final next = await handle
        .chat('two')
        .join()
        .timeout(const Duration(seconds: 10), onTimeout: () => 'TIMED OUT');
    expect(next, 'Hello there.');
    // The stopped turn never recorded itself, so it counts as damaging: the
    // next turn ran on a rebuilt conversation, not on the stopped one.
    expect(reopened, hasLength(1));
    expect(reopened.single.sent, ['two']);
    await sub.cancel();
  });

  test('closing closes the live conversation, rebuilt or not', () async {
    await stopMidTurn('one', first);
    await handle.chat('two').join();
    handle.close();
    expect(reopened.single.closed, isTrue);
  });

  group('rewind', () {
    // Debug logging goes through print in tests too; only the warnings meant
    // for release builds carry the package name.
    List<String> releaseLines(List<String> printed) => [
      for (final line in printed)
        if (line.startsWith('[flutter_edge_ai_litertlm]')) line,
    ];

    Map<String, Object?> textReply(String text) => {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    };

    test('the turn after a stop rewinds the conversation, with the partial '
        'reply put back, and runs on it', () async {
      first.rewindOutcome = StoppedTurnRewind.rewound;
      expect(await handle.chat('one').join(), 'Hello there.');
      await stopMidTurn('two', first);

      expect(await handle.chat('three').join(), 'Hello there.');
      expect(reopened, isEmpty);
      expect(first.closed, isFalse);
      expect(first.sent, ['one', 'two', 'three']);
      expect(first.rewinds, [textReply('Hello')]);
      // The conversation is healthy again: no second recovery.
      await handle.chat('four').join();
      expect(first.rewinds, hasLength(1));
    });

    test('a stop that reached native after the turn had finished keeps the '
        'conversation as it is, quietly', () async {
      first.rewindOutcome = StoppedTurnRewind.notCancelled;
      final printed = <String>[];
      await runZoned(
        () async {
          await stopMidTurn('one', first);
          expect(await handle.chat('two').join(), 'Hello there.');
          await handle.chat('three').join();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      expect(first.rewinds, hasLength(1));
      expect(first.sent, ['one', 'two', 'three']);
      expect(first.closed, isFalse);
      expect(reopened, isEmpty);
      expect(releaseLines(printed), isEmpty);
    });

    test('a conversation that cannot rewind is rebuilt quietly', () async {
      final printed = <String>[];
      await runZoned(
        () async {
          await stopMidTurn('one', first);
          await handle.chat('two').join();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      expect(first.rewinds, hasLength(1));
      expect(reopened.single.sent, ['two']);
      expect(releaseLines(printed), isEmpty);
    });

    test('a failed rewind rebuilds the conversation and says so in release '
        'builds', () async {
      first.rewindOutcome = StoppedTurnRewindException(13, 'prefill failed');
      final printed = <String>[];
      await runZoned(
        () async {
          await stopMidTurn('one', first);
          expect(await handle.chat('two').join(), 'Hello there.');
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      expect(first.closed, isTrue);
      expect(reopened.single.sent, ['two']);
      final warning = releaseLines(printed).single;
      expect(warning, contains('could not rewind'));
      expect(warning, contains('prefill failed'));
    });

    test('on the NPU a stop rebuilds without trying to rewind', () async {
      handle = RecoveringConversationHandle(
        first,
        reopen: (messagesJson) async {
          final c = _Conversation('rebuilt', seed: messagesJson);
          reopened.add(c);
          return c;
        },
        canRewind: false,
      );
      first.rewindOutcome = StoppedTurnRewind.rewound;
      await stopMidTurn('one', first);
      await handle.chat('two').join();
      expect(first.rewinds, isEmpty);
      expect(reopened.single.sent, ['two']);
    });

    test('a stop during the rewind is not sent to native: the rewind '
        'finishes and the turn returns before reaching the model', () async {
      first.rewindOutcome = StoppedTurnRewind.rewound;
      await stopMidTurn('one', first);
      final cancelsAfterStop = first.cancels;

      final gate = first.rewindGate = Completer<void>();
      final pending = handle.chat('two').join();
      await pumpEventQueue();
      handle.cancelGeneration();
      expect(
        first.cancels,
        cancelsAfterStop,
        reason: 'a native cancel would abort the rewind\'s prefill',
      );
      gate.complete();

      expect(await pending, isEmpty);
      expect(first.sent, ['one']);
      // Rewound and nothing generated since: the next turn just runs.
      first.rewindGate = null;
      expect(await handle.chat('three').join(), 'Hello there.');
      expect(first.rewinds, hasLength(1));
      expect(reopened, isEmpty);
    });

    test('closing during a rewind closes the conversation once the rewind '
        'returns, not under it', () async {
      first.rewindOutcome = StoppedTurnRewind.rewound;
      await stopMidTurn('one', first);

      final gate = first.rewindGate = Completer<void>();
      final pending = handle.chat('two').join();
      await pumpEventQueue();
      handle.close();
      expect(first.closed, isFalse);
      gate.complete();

      await expectLater(pending, throwsStateError);
      expect(first.closed, isTrue);
      expect(reopened, isEmpty);
    });

    test('a stopped turn that winds down after the next turn started is '
        'rebuilt, not rewound: its reply is not known in time', () async {
      handle = RecoveringConversationHandle(
        first,
        reopen: (messagesJson) async {
          final c = _Conversation('rebuilt', seed: messagesJson);
          reopened.add(c);
          return c;
        },
        windDownTimeout: const Duration(milliseconds: 100),
      );
      first.rewindOutcome = StoppedTurnRewind.rewound;
      final sub = handle.chat('one').listen(null)..pause();
      await pumpEventQueue();
      handle.cancelGeneration();

      expect(await handle.chat('two').join(), 'Hello there.');
      expect(first.rewinds, isEmpty);
      expect(reopened.single.sent, ['two']);

      // When it does wind down, its reply belongs to a turn that is no longer
      // the conversation's last, so it is not put back.
      reopened.single.rewindOutcome = StoppedTurnRewind.rewound;
      await sub.cancel();
      await handle.chat('three').join();
      expect(reopened.first.rewinds, isEmpty);
      expect(reopened, hasLength(2));
    });

    test('a turn started before the stopped one has wound down rewinds with '
        'its reply', () async {
      first.rewindOutcome = StoppedTurnRewind.rewound;
      final gate = first.hold = Completer<void>();
      final stopped = handle.chat('one').join();
      await pumpEventQueue();
      handle.cancelGeneration();

      final next = handle.chat('two').join();
      await pumpEventQueue();
      gate.complete();
      await stopped;
      expect(await next, 'Hello there.');

      expect(first.rewinds, [textReply('Hello')]);
      expect(first.sent, ['one', 'two']);
      expect(reopened, isEmpty);
    });
  });
}
