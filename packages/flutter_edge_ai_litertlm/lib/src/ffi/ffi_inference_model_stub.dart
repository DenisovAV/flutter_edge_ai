// Web stub for ffi_inference_model.dart
//
// Web build never reaches FFI code paths — the web plugin (FlutterEdgeAiWeb)
// registers itself as FlutterEdgeAiPlugin.instance via registerWith(), so the
// mobile/desktop branch in mobile/flutter_edge_ai_mobile.dart never executes.
// This stub exists purely so the import graph compiles on web (no dart:ffi).

import 'package:flutter/foundation.dart';

import 'package:flutter_edge_ai/engine.dart';
import 'litert_lm_client_stub.dart';

class FfiInferenceModel extends InferenceModel with CloseNotifier {
  FfiInferenceModel({
    required LiteRtLmFfiClient ffiClient,
    required int maxTokens,
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.litertlm,
    PreferredBackend? activeBackend,
    PreferredBackend? activeVisionBackend,
    PreferredBackend? activeAudioBackend,
    bool supportImage = false,
    bool supportAudio = false,
    MultimodalOrder? multimodalOrder,
    int? maxConcurrentSessions,
    required VoidCallback onClose,
  }) {
    throw UnsupportedError(
      'FfiInferenceModel is not available on web — use FlutterEdgeAiWeb instead.',
    );
  }

  @override
  ModelFileType get fileType =>
      throw UnsupportedError('web stub — never instantiated');

  @override
  int get maxTokens => throw UnsupportedError('web stub — never instantiated');

  @override
  PreferredBackend? get activeBackend =>
      throw UnsupportedError('web stub — never instantiated');

  @override
  InferenceModelSession? get session => null;

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) => throw UnsupportedError('web stub — never instantiated');

  @override
  Future<void> close() =>
      throw UnsupportedError('web stub — never instantiated');
}
