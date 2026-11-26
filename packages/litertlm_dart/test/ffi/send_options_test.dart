// A message's options on their way to native: through the conversation
// handle to the optional args, the per-send extra_context, and the release
// gate that holds the C functions the options call.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:litertlm_dart/bindings.dart'
    show
        LiteRtLmBindings,
        LiteRtLmConversation,
        LiteRtLmConversationOptionalArgs;
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

  test('an unconstrained send goes without the conversation\'s response '
      'format; any other send carries it', () async {
    // What native's set_constraint is handed; the seam stands in for the
    // send, the bindings for the optional args' setter.
    final installed = <String>[];
    final setConstraint =
        NativeCallable<
          UnsignedInt Function(
            Pointer<LiteRtLmConversationOptionalArgs>,
            UnsignedInt,
            Pointer<Char>,
          )
        >.isolateLocal((
          Pointer<LiteRtLmConversationOptionalArgs> _,
          int _,
          Pointer<Char> schema,
        ) {
          installed.add(schema.cast<Utf8>().toDartString());
          return 0;
        }, exceptionalReturn: 1);
    final lastError = NativeCallable<Pointer<Char> Function()>.isolateLocal(
      () => nullptr,
    );
    addTearDown(() {
      setConstraint.close();
      lastError.close();
    });
    final symbols = <String, Pointer<Void>>{
      'litert_lm_conversation_optional_args_set_constraint': setConstraint
          .nativeFunction
          .cast(),
      'litert_lm_get_last_error_message': lastError.nativeFunction.cast(),
    };
    final client = LiteRtLmFfiClient()
      ..bindingsForTest = LiteRtLmBindings.fromLookup(
        <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
      );
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7200);
    final schemas = <String?>[];
    client
      ..registerLiveForTest(conv)
      ..structuredSendForTest = (c, schema) {
        schemas.add(schema);
        final send = client.newTurnForTest(c);
        Future.microtask(send.finished);
        return send;
      };
    final handle = LiteRtLmConversationHandle.forTest(
      client,
      conversation: conv,
      jsonSchema: '{"type":"object"}',
    );
    await handle
        .chatRawMessage(
          '{"role":"user"}',
          options: const SendOptions(unconstrained: true),
        )
        .toList();
    await handle.chatRawMessage('{"role":"tool"}').toList();
    expect(schemas, [null, '{"type":"object"}']);
    expect(installed, ['{"type":"object"}']);
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
      'engine_settings_set_selected_signatures',
      'conversation_config_set_extra_context',
      'optional_args_set_tool_choice',
      'optional_args_set_max_output_tokens',
      'optional_args_set_visual_token_budget',
      'conversation_config_set_prompt_template',
      'conversation_config_set_stream_tool_calls',
      'engine_settings_set_max_vision_tokens_per_image',
      'conversation_clone',
      'conversation_render_',
      'conversation_get_token_count',
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
