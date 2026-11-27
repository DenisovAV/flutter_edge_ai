// What the 0.20.0 parity options hand the C API, through fake bindings that
// record each setter: a message's output cap and visual token budget on the
// optional args, a conversation's chat template and tool call streaming on
// its config, and a speculative decoding config whose mode is left to
// inherit.
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:litertlm_dart/bindings.dart'
    show
        LiteRtLmBindings,
        LiteRtLmConversationConfig,
        LiteRtLmConversationOptionalArgs,
        LiteRtLmSpeculativeDecodingConfig;
import 'package:litertlm_dart/src/ffi/send_options.dart';
import 'package:test/test.dart';

/// Bindings whose setters record `name(args)` in [calls].
({LiteRtLmBindings bindings, List<String> calls}) _recording() {
  final calls = <String>[];
  final callables = <NativeCallable<Function>>[];
  final symbols = <String, Pointer<Void>>{};
  void add<T extends Function>(String name, NativeCallable<T> callable) {
    callables.add(callable);
    symbols[name] = callable.nativeFunction.cast();
  }

  add(
    'litert_lm_conversation_optional_args_set_max_output_tokens',
    NativeCallable<
      UnsignedInt Function(Pointer<LiteRtLmConversationOptionalArgs>, Int)
    >.isolateLocal((Pointer<LiteRtLmConversationOptionalArgs> _, int v) {
      calls.add('max_output_tokens($v)');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_optional_args_set_visual_token_budget',
    NativeCallable<
      UnsignedInt Function(Pointer<LiteRtLmConversationOptionalArgs>, Int)
    >.isolateLocal((Pointer<LiteRtLmConversationOptionalArgs> _, int v) {
      calls.add('visual_token_budget($v)');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_config_set_prompt_template',
    NativeCallable<
      UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, Pointer<Char>)
    >.isolateLocal((Pointer<LiteRtLmConversationConfig> _, Pointer<Char> t) {
      calls.add('prompt_template(${t.cast<Utf8>().toDartString()})');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_config_set_stream_tool_calls',
    NativeCallable<
      UnsignedInt Function(
        Pointer<LiteRtLmConversationConfig>,
        Bool,
        Pointer<Char>,
      )
    >.isolateLocal((
      Pointer<LiteRtLmConversationConfig> _,
      bool on,
      Pointer<Char> channel,
    ) {
      calls.add(
        'stream_tool_calls($on, ${channel.cast<Utf8>().toDartString()})',
      );
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_speculative_decoding_config_set_mode',
    NativeCallable<
      UnsignedInt Function(
        Pointer<LiteRtLmSpeculativeDecodingConfig>,
        UnsignedInt,
      )
    >.isolateLocal((Pointer<LiteRtLmSpeculativeDecodingConfig> _, int mode) {
      calls.add('mode($mode)');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_speculative_decoding_config_set_lenience',
    NativeCallable<
      UnsignedInt Function(Pointer<LiteRtLmSpeculativeDecodingConfig>, Float)
    >.isolateLocal((Pointer<LiteRtLmSpeculativeDecodingConfig> _, double l) {
      calls.add('lenience($l)');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_get_last_error_message',
    NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
  );
  addTearDown(() {
    for (final c in callables) {
      c.close();
    }
  });
  return (
    bindings: LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    ),
    calls: calls,
  );
}

void main() {
  _callSites();

  test("a send's output cap and visual token budget reach the optional "
      'args; a send without them sets neither', () {
    final r = _recording();
    final args = Pointer<LiteRtLmConversationOptionalArgs>.fromAddress(0x10);
    applySendOptions(
      r.bindings,
      args,
      const SendOptions(maxOutputTokens: 64, visualTokenBudget: 70),
    );
    expect(r.calls, ['max_output_tokens(64)', 'visual_token_budget(70)']);
    r.calls.clear();
    applySendOptions(r.bindings, args, SendOptions.none);
    expect(r.calls, isEmpty);
  });

  test("a conversation's chat template and tool call streaming reach its "
      'config, with Swift\'s channel name; neither is set unasked', () {
    final r = _recording();
    final config = Pointer<LiteRtLmConversationConfig>.fromAddress(0x20);
    applyConversationExtras(
      r.bindings,
      config,
      const ConversationExtras(
        chatTemplate: '{{ messages }}',
        streamToolCalls: true,
      ),
    );
    expect(r.calls, [
      'prompt_template({{ messages }})',
      'stream_tool_calls(true, tool_call)',
    ]);
    r.calls.clear();
    applyConversationExtras(r.bindings, config, ConversationExtras.none);
    expect(r.calls, isEmpty);
  });

  test('a speculative decoding config sets only the fields given: a mode '
      'left null is inherited', () {
    final r = _recording();
    final config = Pointer<LiteRtLmSpeculativeDecodingConfig>.fromAddress(0x30);
    applySpeculativeDecodingFields(
      r.bindings,
      config,
      mode: null,
      lenience: 0.5,
    );
    expect(r.calls, ['lenience(0.5)']);
    r.calls.clear();
    applySpeculativeDecodingFields(r.bindings, config, mode: 2, lenience: null);
    expect(r.calls, ['mode(2)']);
  });
}

/// The production call sites of the helpers above, read from the client's
/// source: a conversation's create applies the extras, and both speculative
/// decoding configs (engine and session) go through the field setter.
void _callSites() {
  test('the client applies the extras and the speculative fields', () {
    final client = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    final create = client.substring(
      client.indexOf(
        'Future<Pointer<LiteRtLmConversation>> _createRawConversation(',
      ),
      client.indexOf('void _setConstraintProvider('),
    );
    expect(create, contains('applyConversationExtras(b, convConfig, extras);'));
    expect(
      RegExp(r'applySpeculativeDecodingFields\(').allMatches(client).length,
      2,
    );
    expect(client, contains('mode: speculative.mode?.index,'));
  });
}
