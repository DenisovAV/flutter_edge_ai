// The web model's engine: the active model's source, as core resolves it on
// the page, handed to litertlm_dart's web `Engine`. dart:js_interop (the
// OPFS stream), so web only.

import 'package:flutter_edge_ai/engine_web.dart';
// The web Engine by name: through the public library the analyzer would see
// the native one.
import 'package:litertlm_dart/internal_web.dart'
    show Engine, createConversationWithDefault, createWebEngine;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import '../adapter/web_inference_model.dart';

/// Loads the model [resolver] resolves on WebGPU, as `@litert-lm/core` does
/// by default: a `blob:` URL, or under `WebStorageMode.streaming` the OPFS
/// file as a stream, which a model over 2 GB needs (a `blob:` URL fetch trips
/// Chrome's `ERR_BLOB_OUT_OF_MEMORY`).
///
/// [maxTokens] is the context window, passed through as natively: the web
/// runtime takes it as given (no 1024-token floor there).
///
/// [supportImage] loads the vision encoder on the GPU, [supportAudio] the
/// audio encoder on the CPU, as the native Gemma 4 bundles declare it; both
/// ran on 0.19.0 with Gemma 4 E2B's GPU export (2026-11-23).
Future<WebLlmEngine> createLiteRtLmWebEngine(
  WebModelSourceResolver resolver, {
  required int maxTokens,
  bool supportImage = false,
  bool supportAudio = false,
}) async {
  final resolved = await resolver.resolveActiveInferenceModel();
  final Engine engine;
  switch (resolved.model) {
    case BlobUrlModelSource(:final url):
      engine = await createWebEngine(
        lm.EngineConfig(
          modelPath: url,
          backend: const lm.Backend.gpu(),
          maxNumTokens: maxTokens,
          visionBackend: supportImage ? const lm.Backend.gpu() : null,
          audioBackend: supportAudio ? const lm.Backend.cpu() : null,
        ),
      );
    case final OpfsStreamModelSource source:
      engine = await createWebEngine(
        lm.EngineConfig(
          modelPath: source.filename,
          backend: const lm.Backend.gpu(),
          maxNumTokens: maxTokens,
          visionBackend: supportImage ? const lm.Backend.gpu() : null,
          audioBackend: supportAudio ? const lm.Backend.cpu() : null,
        ),
        model: await source.openStream(),
      );
  }
  return _LmWebLlmEngine(engine);
}

final class _LmWebLlmEngine implements WebLlmEngine {
  _LmWebLlmEngine(this._engine);

  final Engine _engine;

  @override
  Future<lm.Conversation> openConversation(
    lm.ConversationConfig config,
    lm.SamplerConfig? defaultSamplerConfig,
  ) => createConversationWithDefault(_engine, config, defaultSamplerConfig);

  @override
  Future<void> close() => _engine.close();
}
