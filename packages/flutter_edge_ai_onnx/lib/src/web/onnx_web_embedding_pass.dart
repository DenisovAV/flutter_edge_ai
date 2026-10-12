// The web ONNX embedding pass (onnxruntime-web) — what the web
// `OnnxEmbeddingBackend.describe` hands core, which hosts it inline on the
// page, checks every request and closes it.
//
// Pure Dart: it imports neither `ort_web_client.dart` nor core's
// `engine_web.dart` (both `dart:js_interop`). The ORT session and the URL
// resolver arrive in its config, so the VM tests run it with a fake client
// and a fake resolver; the web backend wires the real ones.
//
// onnxruntime-web reports no static input shape, so on web every graph is
// dynamic: no padding, `maxInputTokens: null`.

import 'package:flutter_edge_ai/engine.dart';

import '../embedding/ort_client.dart';
import '../embedding/ort_token_graph.dart';

/// What the web `OnnxEmbeddingBackend.describe` hands core.
///
/// Hosted inline, never sent across an isolate, so it may carry functions
/// that are not top-level.
final class OnnxWebEmbeddingConfig {
  const OnnxWebEmbeddingConfig({
    required this.modelPath,
    required this.tokenizerPath,
    required this.tokenizerFactory,
    required this.resolveUrl,
    required this.revokeUrl,
    required this.clientFactory,
  });

  /// The paths core registered for the installed files — under
  /// `WebStorageMode.streaming` an `opfs://` path neither `fetch()` nor
  /// `ort.InferenceSession.create()` can open.
  final String modelPath;
  final String tokenizerPath;

  /// From core's tokenizer registry.
  final EmbeddingTokenizerFactory tokenizerFactory;

  /// Turns [modelPath] / [tokenizerPath] into a URL the page can fetch
  /// (`resolveWebModelUrl`: `opfs://` → `blob:`, anything else unchanged).
  final Future<String> Function(String path) resolveUrl;

  /// `URL.revokeObjectURL`: releases a URL [resolveUrl] created. The pass
  /// owns those (the `blob:` URL of an `opfs://` path) and revokes them once
  /// consumed; a path it did not resolve from `opfs://` is never revoked.
  final void Function(String url) revokeUrl;

  /// The ORT session (`OrtWebClient` on the page).
  final OrtClient Function() clientFactory;
}

/// The descriptor factory.
EmbeddingPass buildOnnxWebEmbeddingPass(OnnxWebEmbeddingConfig config) =>
    OnnxWebEmbeddingPass(config);

/// The web ONNX embedding pass. Text only.
final class OnnxWebEmbeddingPass extends TokenEmbeddingPass {
  OnnxWebEmbeddingPass(OnnxWebEmbeddingConfig config)
    : _config = config,
      super(
        tokenizerPath: config.tokenizerPath,
        tokenizerFactory: _resolvingFirst(config),
      );

  final OnnxWebEmbeddingConfig _config;

  OrtClient? _client;
  OrtIoSpec? _spec;

  /// The registry's tokenizer factory, handed the RESOLVED tokenizer URL: it
  /// fetches the file, and an `opfs://` path is not fetchable. The URL is
  /// released once the factory has read it.
  static EmbeddingTokenizerFactory _resolvingFirst(
    OnnxWebEmbeddingConfig config,
  ) => (path) async {
    final url = await config.resolveUrl(path);
    try {
      return await config.tokenizerFactory(url);
    } finally {
      _releaseIfCreated(config, path, url);
    }
  };

  /// Revokes [url] when this pass created it — the `blob:` URL of an
  /// `opfs://` [rawPath] — and never a URL core owns. Each holds a
  /// model-sized Blob until the page unloads otherwise.
  static void _releaseIfCreated(
    OnnxWebEmbeddingConfig config,
    String rawPath,
    String url,
  ) {
    if (rawPath.startsWith('opfs://')) config.revokeUrl(url);
  }

  @override
  Future<TokenPassGraph> openGraph() async {
    final modelUrl = await _config.resolveUrl(_config.modelPath);
    final OrtClient client;
    final OrtIoSpec spec;
    try {
      client = _config.clientFactory();
      // Held before the session opens, so closeGraph releases it whatever
      // fails after this — the load itself, or the dimension probe after it.
      _client = client;
      spec = await client.load(modelUrl);
    } finally {
      // The session has read the model by now (or failed to).
      _releaseIfCreated(_config, _config.modelPath, modelUrl);
    }
    _spec = spec;
    return describeOrtGraph(client, spec, _config.modelPath);
  }

  @override
  Future<ForwardResult> runTokens(TokenizedInput input) async {
    final client = _client;
    final spec = _spec;
    if (client == null || spec == null) {
      throw StateError('OnnxWebEmbeddingPass ran without an open session');
    }
    return runOrtTokens(client, spec, input);
  }

  @override
  Future<void> closeGraph() async {
    final client = _client;
    _client = null;
    _spec = null;
    await client?.close();
  }
}
