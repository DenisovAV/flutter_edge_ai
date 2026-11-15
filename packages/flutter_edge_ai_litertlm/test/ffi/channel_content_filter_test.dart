// LiteRT-LM 0.19 rewinds over a whole reply to strip its channel content
// (a thought) from the KV cache, which the NPU executor refuses ("only
// supports rolling back one token at the end of decode"). These tests hold
// that every conversation of a model that cannot rewind turns the filter off,
// and that a model that can leaves the native default alone.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('filterChannelContent', () {
    for (final (backend, linear, expected) in [
      (PreferredBackend.npu, false, false),
      (PreferredBackend.npu, null, false),
      (PreferredBackend.cpu, true, false),
      (PreferredBackend.gpu, true, false),
      (PreferredBackend.cpu, false, true),
      (PreferredBackend.gpu, false, true),
      (PreferredBackend.cpu, null, false),
      (PreferredBackend.gpu, null, false),
      (null, false, true),
    ]) {
      test('${backend?.name}, linear attention state $linear: $expected', () {
        final model = _model(
          LiteRtLmFfiClient(),
          backend: backend,
          linearAttentionState: linear,
        );
        expect(model.filterChannelContent, expected);
        expect(
          model.filterChannelContent,
          model.openSessionNoRewindReason == null,
          reason: 'on only where every conversation is known to rewind',
        );
      });
    }
  });

  group('conversation config', () {
    for (final (backend, linear, calls) in [
      (PreferredBackend.npu, false, [false]),
      (PreferredBackend.cpu, true, [false]),
      (PreferredBackend.cpu, null, [false]),
      (PreferredBackend.cpu, false, <bool>[]),
      (PreferredBackend.gpu, false, <bool>[]),
    ]) {
      final label = '${backend.name}, linear attention state $linear';

      test('createSession on $label', () async {
        final client = _RecordingClient();
        final model = _model(
          client,
          backend: backend,
          linearAttentionState: linear,
        );
        final session = await model.createSession();
        expect(client.recorder.filterCalls, calls);
        await session.close();
        await model.close();
      });

      test('a native openSession on $label', () async {
        final client = _RecordingClient();
        final model = _model(
          client,
          backend: backend,
          linearAttentionState: linear,
          backing: OpenSessionBacking.native,
        );
        final session = await model.openSession();
        expect(client.recorder.filterCalls, calls);
        await session.close();
        await model.close();
      });

      test('a virtual openSession on $label', () async {
        final client = _RecordingClient();
        final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
        client
          ..structuredSendForTest = (conv, _) {
            final send = client.newTurnForTest(conv);
            sends.add(send);
            return send;
          }
          ..metricsForTest = (_) => SessionMetrics();
        final model = _model(
          client,
          backend: backend,
          linearAttentionState: linear,
          backing: OpenSessionBacking.virtual,
        );
        final session = await model.openSession();
        expect(client.recorder.filterCalls, isEmpty, reason: 'no create yet');

        await session.addQueryChunk(const Message(text: 'hi', isUser: true));
        final reply = session.getResponse();
        await pumpEventQueue();
        expect(client.recorder.filterCalls, calls);
        sends.single
          ..chunk(
            '{"role":"assistant","content":['
            '{"type":"text","text":"hello"}]}',
          )
          ..finished();
        expect(await reply, 'hello');
        await session.close();
        await model.close();
      });
    }
  });
  group('legacy createConversation', () {
    final sampling = SamplingParams.resolve(
      const SamplingParams(),
      modelType: ModelType.gemmaIt,
    );
    for (final (backend, Future<bool> Function(String) read, calls) in [
      ('npu', (_) async => false, [false]),
      ('cpu', (_) async => true, [false]),
      ('gpu', (_) async => true, [false]),
      (
        'cpu',
        (String path) async =>
            throw PathNotFoundException(path, const OSError('missing')),
        [false],
      ),
      ('cpu', (_) async => false, <bool>[]),
      ('gpu', (_) async => false, <bool>[]),
    ]) {
      test('$backend, filter calls $calls', () async {
        final client = _RecordingClient()
          ..loadedModelForTest(backend: backend, modelPath: 'model.litertlm')
          ..linearAttentionStateReader = read;
        await client.createConversation(sampling: sampling);
        expect(client.recorder.filterCalls, calls);
      });
    }

    test('reads the file once per load', () async {
      var reads = 0;
      final client = _RecordingClient()
        ..loadedModelForTest(backend: 'cpu', modelPath: 'model.litertlm')
        ..linearAttentionStateReader = (_) async {
          reads++;
          return false;
        };
      await client.createConversation(sampling: sampling);
      await client.createConversation(sampling: sampling);
      expect(reads, 1);
    });

    test('no loaded model counts as cannot rewind', () async {
      final client = _RecordingClient()..loadedModelForTest(backend: 'cpu');
      await client.createConversation(sampling: sampling);
      expect(client.recorder.filterCalls, [false]);
    });
  });
}

FfiInferenceModel _model(
  LiteRtLmFfiClient client, {
  required PreferredBackend? backend,
  required bool? linearAttentionState,
  OpenSessionBacking backing = OpenSessionBacking.virtual,
}) => FfiInferenceModel(
  ffiClient: client,
  maxTokens: 1024,
  modelType: ModelType.gemmaIt,
  activeBackend: backend,
  openSessionBacking: backing,
  linearAttentionState: linearAttentionState,
  onClose: () {},
);

/// A client whose conversation create stops at the test seam, with bindings
/// that record the channel filter setter.
class _RecordingClient extends LiteRtLmFfiClient {
  _RecordingClient() {
    bindingsForTest = recorder.bindings;
    addTearDown(recorder.close);
    structuredCreateForTest = (_, _) async {
      final conv = Pointer<LiteRtLmConversation>.fromAddress(
        0x7000 + _created++ * 0x10,
      );
      registerLiveForTest(conv);
      return conv;
    };
  }

  final recorder = _FilterRecorder();
  int _created = 0;
}

class _FilterRecorder {
  _FilterRecorder() {
    final symbols = <String, Pointer<Void>>{
      'litert_lm_get_last_error_message': _retain(
        NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
      ),
      'litert_lm_conversation_config_set_filter_channel_content_from_kv_cache':
          _retain(
            NativeCallable<
              UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, Bool)
            >.isolateLocal((
              Pointer<LiteRtLmConversationConfig> _,
              bool filter,
            ) {
              filterCalls.add(filter);
              return 0;
            }, exceptionalReturn: 1),
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

  final filterCalls = <bool>[];
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
