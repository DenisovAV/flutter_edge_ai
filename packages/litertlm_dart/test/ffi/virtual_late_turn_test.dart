// A virtual session's stopped turn whose consumer paused it ends only after
// the next turn took the conversation over (past the 5 s wind-down bound).
// That late end owns nothing any more: not the busy flag a stop of the newer
// turn reads, nor the history a rebuild replays.
import 'dart:convert';
import 'dart:ffi';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('a stopped turn that ends under a newer one leaves its busy flag and '
      'the history alone', () async {
    final client = LiteRtLmFfiClient();
    final seeds = <String?>[];
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    client
      ..virtualCreateForTest = (history) async {
        seeds.add(history);
        final c = Pointer<LiteRtLmConversation>.fromAddress(
          0x7000 + 16 * seeds.length,
        );
        client.registerLiveForTest(c);
        return c;
      }
      ..virtualSendForTest = (c) {
        final send = client.newTurnForTest(c);
        sends.add(send);
        return send;
      };
    final handle = VirtualConversationHandle(
      client: client,
      systemMessage: null,
      toolsJson: null,
      sampling: const Sampler(
        temperature: 1,
        topK: 40,
        topP: 0.95,
        randomSeed: 1,
      ),
      samplingExplicit: false,
      multimodalOrder: MediaOrder.imagesAudioText,
      filterChannelContent: false,
      toolCallsOf: nativeToolCalls,
      freshConversationEachTurn: true,
    );
    String reply(String t) => jsonEncode({
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': t},
      ],
    });

    // A streams one chunk, its consumer pauses, and it is stopped: native
    // ends it, but the paused turn cannot reach its end.
    final a = handle.chat('one').listen(null);
    await Future<void>.delayed(Duration.zero);
    // Paused before its chunk arrives: the turn yields it and stays parked
    // on that `yield`, unable to reach its end.
    a.pause();
    sends.single.chunk(reply('o'));
    await Future<void>.delayed(Duration.zero);
    handle.cancelGeneration();
    sends.single.cancelled();

    // B gives A its bounded wind-down, then takes the conversation.
    final b = handle.chat('two').join();
    for (var i = 0; sends.length < 2 && i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(sends, hasLength(2));

    // A ends now, under B.
    a.resume();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // B is stopped before it produced anything: taken back (Rule A), which
    // needs the stop to be recorded while B is in flight.
    handle.cancelGeneration();
    sends.last.cancelled();
    expect(await b, '');

    final c = handle.chat('three').join();
    for (var i = 0; sends.length < 3 && i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    sends.last
      ..chunk(reply('ok'))
      ..finished();
    await c;
    final replayed = [
      for (final m in jsonDecode(seeds.last ?? '[]') as List<Object?>)
        jsonEncode((m as Map)['content']),
    ];
    expect(
      replayed.where((m) => m.contains('two')),
      isEmpty,
      reason: '$replayed',
    );
    expect(
      replayed.where((m) => m.contains('one')),
      isEmpty,
      reason: '$replayed',
    );
    await a.cancel();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
