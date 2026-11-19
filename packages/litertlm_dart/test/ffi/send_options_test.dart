// A message's options on their way to native: through the conversation
// handle to the optional args, the per-send extra_context, and the release
// gate that holds the C functions the options call.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:litertlm_dart/bindings.dart' show LiteRtLmConversation;
import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

void main() {
  test("a handle's send hands its options to the optional args", () async {
    final client = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7100);
    client
      ..registerLiveForTest(conv)
      ..structuredSendForTest = (c, _) {
        final send = client.newTurnForTest(c);
        Future.microtask(send.finished);
        return send;
      };
    final handle = LiteRtLmConversationHandle.forTest(
      client,
      conversation: conv,
    );
    final options = SendOptions(
      repetitionPenalty: RepetitionPenaltyConfig(repetitionPenalty: 1.1),
      suppressTokens: const [1],
      thinkingTokenBudget: 32,
    );
    await handle.chatRawMessage('{"role":"user"}', options: options).toList();
    expect(client.lastSendOptionsForTest, same(options));
  });

  test('the per-send extra_context keeps the thinking switch on top', () {
    expect(jsonDecode(sendExtraContext(true, null)), thinkingContext(true));
    expect(jsonDecode(sendExtraContext(false, const {'a': 1})), {
      'a': 1,
      ...thinkingContext(false),
    });
    // A template variable cannot turn thinking on behind the caller's back.
    final key = thinkingContext(false).keys.first;
    expect(
      jsonDecode(sendExtraContext(false, {key: true}))[key],
      thinkingContext(false)[key],
    );
  });

  test('the release gate lists every C function the options call', () {
    final sources = [
      File('lib/src/ffi/send_options.dart').readAsStringSync(),
      File('lib/src/ffi/litert_lm_client.dart').readAsStringSync(),
    ].join('\n');
    const optionCalls = {
      'repetition_penalty',
      'no_repeat_ngram',
      'suppress_tokens',
      'speculative_decoding_config',
      'engine_settings_set_num_threads',
      'conversation_config_set_extra_context',
    };
    final called = {
      for (final m in RegExp(r'b\.(litert_lm_[a-z_]+)\b').allMatches(sources))
        if (optionCalls.any(m.group(1)!.contains)) m.group(1)!,
    };
    final gate = File(
      'native/litert_lm/check_embedding_exports.py',
    ).readAsStringSync();
    final listed = RegExp(
      r'OPTION_SYMBOLS = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(gate)!.group(1)!;
    expect({
      for (final m in RegExp(r'"(litert_lm_[a-z_]+)"').allMatches(listed))
        m.group(1)!,
    }, called);
  });

  test('every send applies its options to the optional args it creates', () {
    final client = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    final create = client.substring(
      client.indexOf(
        'Pointer<LiteRtLmConversationOptionalArgs> _createOptionalArgs(',
      ),
      client.indexOf(
        '/// Whether the loaded model keeps linear attention state',
      ),
    );
    expect(create, contains('applySendOptions(b, optionalArgs, options);'));
    expect(
      create,
      contains('options.thinkingTokenBudget ?? thinkingTokenBudget'),
    );
  });
}
