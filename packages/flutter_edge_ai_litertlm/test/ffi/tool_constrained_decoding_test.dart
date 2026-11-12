// EXPERIMENT (exp/npu-no-constrained-tools): a conversation with tools turns
// on LiteRT-LM's tool-call constrained decoding everywhere but on the NPU.

import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sampling = SamplingParams.resolve(
    const SamplingParams(),
    modelType: ModelType.gemmaIt,
  );
  const tools = '[{"type":"function","function":{"name":"f"}}]';

  for (final (backend, withTools, calls) in [
    ('npu', true, <bool>[]),
    ('npu', false, <bool>[]),
    ('cpu', true, [true]),
    ('gpu', true, [true]),
    ('cpu', false, <bool>[]),
  ]) {
    test('$backend, tools $withTools: constrained decoding $calls', () async {
      final client = _RecordingClient()
        ..loadedModelForTest(backend: backend, modelPath: 'model.litertlm')
        ..linearAttentionStateReader = (_) async => false;
      await client.createConversation(
        sampling: sampling,
        toolsJson: withTools ? tools : null,
      );
      expect(client.recorder.constrainedCalls, calls);

      final handle = await client.createConversationHandle(
        toolsJson: withTools ? tools : null,
        sampling: sampling,
        samplingExplicit: false,
        multimodalOrder: MultimodalOrder.imagesAudioText,
        filterChannelContent: true,
      );
      expect(client.recorder.constrainedCalls, [...calls, ...calls]);
      handle.close();
    });
  }
}

class _RecordingClient extends LiteRtLmFfiClient {
  _RecordingClient() {
    bindingsForTest = recorder.bindings;
    addTearDown(recorder.close);
    structuredCreateForTest = (_, _) async {
      final conv = Pointer<LiteRtLmConversation>.fromAddress(
        0x9000 + _created++ * 0x10,
      );
      registerLiveForTest(conv);
      return conv;
    };
  }

  final recorder = _Recorder();
  int _created = 0;
}

class _Recorder {
  _Recorder() {
    final symbols = <String, Pointer<Void>>{
      'litert_lm_get_last_error_message': _retain(
        NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
      ),
      'litert_lm_conversation_config_set_enable_constrained_decoding': _retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, Bool)
        >.isolateLocal((Pointer<LiteRtLmConversationConfig> _, bool on) {
          constrainedCalls.add(on);
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_config_set_filter_channel_content_from_kv_cache':
          _retain(
            NativeCallable<
              UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, Bool)
            >.isolateLocal(
              (Pointer<LiteRtLmConversationConfig> _, bool _) => 0,
              exceptionalReturn: 1,
            ),
          ),
      'litert_lm_conversation_delete': _retain(
        NativeCallable<
          Void Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal((Pointer<LiteRtLmConversation> _) {}),
      ),
      'litert_lm_conversation_cancel_process': _retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal(
          (Pointer<LiteRtLmConversation> _) => 0,
          exceptionalReturn: 1,
        ),
      ),
    };
    bindings = LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    );
  }

  final constrainedCalls = <bool>[];
  final _callables = <NativeCallable>[];
  late final LiteRtLmBindings bindings;

  Pointer<Void> _retain(NativeCallable callable) {
    _callables.add(callable);
    return callable.nativeFunction.cast();
  }

  void close() {
    for (final callable in _callables) {
      callable.close();
    }
  }
}
