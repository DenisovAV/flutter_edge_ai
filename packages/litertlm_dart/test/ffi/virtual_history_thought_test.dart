// A virtual session replays its history without the model's thoughts: a chat
// template renders a model message's text as it is (LiteRT-LM's canonical
// Gemma 4 template strips no thought), and a native conversation's recorded
// history holds none either.
import 'dart:convert';
import 'dart:ffi';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('the replayed reply keeps its text and drops its thought', () async {
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

    final first = handle.chat('one').join();
    for (var i = 0; sends.isEmpty && i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    sends.single
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'channels': {'thought': 'SECRET-THOUGHT'},
        }),
      )
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'VISIBLE-ANSWER'},
          ],
        }),
      )
      ..finished();
    await first;

    final second = handle.chat('two').join();
    for (var i = 0; sends.length < 2 && i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    sends.last.finished();
    await second;

    final replayed = seeds.last ?? '';
    expect(replayed, contains('VISIBLE-ANSWER'));
    expect(replayed, isNot(contains('SECRET-THOUGHT')));
    expect(replayed, isNot(contains('<|channel>')));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
