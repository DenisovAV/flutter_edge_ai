import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_model_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what reaches the native layer, then stops: no engine is loaded.
class _CapturingClient extends LiteRtLmFfiClient {
  _CapturingClient(this._bundle);

  final SamplingParams _bundle;
  ResolvedSampling? sampling;
  bool? samplingExplicit;

  @override
  SamplingParams get bundleSampler => _bundle;

  @override
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    required ResolvedSampling sampling,
    bool samplingExplicit = false,
    int? maxOutputTokens,
  }) {
    this.sampling = sampling;
    this.samplingExplicit = samplingExplicit;
    throw const _Captured();
  }

  @override
  Stream<String> startVirtualTurn({
    required Object conversationToken,
    required String messageJson,
    required List<Map<String, Object?>> history,
    String? systemMessage,
    String? toolsJson,
    required ResolvedSampling sampling,
    bool samplingExplicit = false,
    String? extraContext,
    int? maxOutputTokens,
  }) {
    this.sampling = sampling;
    this.samplingExplicit = samplingExplicit;
    return Stream.error(const _Captured());
  }
}

class _Captured implements Exception {
  const _Captured();
}

FfiInferenceModel _model(_CapturingClient client, ModelType type) =>
    FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: type,
      activeBackend: null,
      onClose: () {},
    );

const _qwen3Bundle = SamplingParams(temperature: 0.6, topK: 20, topP: 0.95);

void main() {
  group('createSession', () {
    test('unset sampling takes the bundle sampler, not greedy', () async {
      final client = _CapturingClient(_qwen3Bundle);
      await expectLater(
        _model(client, ModelType.qwen3).createSession(),
        throwsA(isA<_Captured>()),
      );
      expect(
        client.sampling,
        const ResolvedSampling(
          temperature: 0.6,
          topK: 20,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
      expect(client.samplingExplicit, isFalse);
    });

    test('a bundle without a sampler gets the family defaults', () async {
      final client = _CapturingClient(const SamplingParams());
      await expectLater(
        _model(client, ModelType.gemma4).createSession(),
        throwsA(isA<_Captured>()),
      );
      expect(
        client.sampling,
        const ResolvedSampling(
          temperature: 1.0,
          topK: 64,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
    });

    test('one field set by the caller merges with the bundle', () async {
      final client = _CapturingClient(_qwen3Bundle);
      await expectLater(
        _model(client, ModelType.qwen3).createSession(temperature: 0.1),
        throwsA(isA<_Captured>()),
      );
      expect(
        client.sampling,
        const ResolvedSampling(
          temperature: 0.1,
          topK: 20,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
      expect(client.samplingExplicit, isTrue);
    });

    test('a temperature alone skips a greedy bundle', () async {
      final client = _CapturingClient(const SamplingParams(topK: 1));
      await expectLater(
        _model(client, ModelType.gemma4).createSession(temperature: 0.9),
        throwsA(isA<_Captured>()),
      );
      expect(
        client.sampling,
        const ResolvedSampling(
          temperature: 0.9,
          topK: 64,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
    });

    test('an invalid value throws before anything reaches native', () async {
      final client = _CapturingClient(const SamplingParams());
      await expectLater(
        _model(client, ModelType.gemma4).createSession(topK: 0),
        throwsArgumentError,
      );
      expect(client.sampling, isNull);
    });

    test('thinking picks the family set for thinking', () async {
      final client = _CapturingClient(const SamplingParams());
      await expectLater(
        _model(client, ModelType.qwen3).createSession(enableThinking: true),
        throwsA(isA<_Captured>()),
      );
      expect(client.sampling?.temperature, 0.6);
      expect(client.sampling?.topP, 0.95);
    });
  });

  test('openSession resolves the same way', () async {
    final client = _CapturingClient(_qwen3Bundle);
    final session = await _model(client, ModelType.qwen3).openSession(topK: 1);
    await session.addQueryChunk(const Message(text: 'hi', isUser: true));
    await expectLater(session.getResponse(), throwsA(isA<_Captured>()));
    expect(
      client.sampling,
      const ResolvedSampling(
        temperature: 0.6,
        topK: 1,
        topP: 0.95,
        randomSeed: 1,
      ),
    );
    expect(client.samplingExplicit, isTrue);
  });

  group('bundleSamplerFrom', () {
    test('no sampler in the bundle is empty', () {
      expect(
        bundleSamplerFrom(type: 0, temperature: 0, topK: 0, topP: 0).isEmpty,
        isTrue,
      );
    });

    test('a greedy bundle becomes topK 1', () {
      expect(
        bundleSamplerFrom(type: 3, temperature: 0, topK: 0, topP: 0),
        const SamplingParams(topK: 1),
      );
    });

    test('zeros the C API returns for missing fields stay unset', () {
      expect(
        bundleSamplerFrom(type: 2, temperature: 0.6, topK: 0, topP: 0.95),
        const SamplingParams(temperature: 0.6, topP: 0.95),
      );
    });

    test('a TOP_K bundle keeps its values and gets no nucleus cut', () {
      expect(
        bundleSamplerFrom(type: 1, temperature: 1.0, topK: 40, topP: 0),
        const SamplingParams(temperature: 1.0, topK: 40, topP: 1.0),
      );
    });
  });
}
