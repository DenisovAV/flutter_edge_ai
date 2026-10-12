// The native ONNX Runtime embedding pass (plain ORT, no GenAI) — what
// `OnnxEmbeddingBackend.describe` hands core. Core builds it in its embedding
// worker isolate, hosts it, checks every request and closes it.
//
// `TokenEmbeddingPass` owns the tokenizer, the task prefix, the length check
// and the finalisation; this pass owns one ORT session behind the [OrtClient]
// seam, so it is testable with a fake client and zero dlopen. What it does
// with the open session — describe the graph, pad a static graph, default
// the mask — is `ort_token_graph.dart`, shared with the web pass.

import 'package:flutter_edge_ai/engine.dart';

import 'ort_client.dart';
import 'ort_ffi_client.dart';
import 'ort_token_graph.dart';

/// What an [OnnxEmbeddingPass] runs: the `.onnx`/`.ort` model, its tokenizer
/// file, and the tokenizer factory (from core's tokenizer registry).
///
/// Crosses to core's worker isolate, so [tokenizerFactory] must be a
/// top-level or static function.
final class OnnxEmbeddingConfig {
  const OnnxEmbeddingConfig({
    required this.modelPath,
    required this.tokenizerPath,
    required this.tokenizerFactory,
  });

  final String modelPath;
  final String tokenizerPath;
  final EmbeddingTokenizerFactory tokenizerFactory;
}

/// Native ONNX Runtime embedding pass over a single-file `.onnx`/`.ort`
/// export: WordPiece (BERT, MiniLM) and SentencePiece (EmbeddingGemma) alike,
/// on CPU.
///
/// `maxInputTokens` is the graph's static sequence length; a dynamic-shape
/// graph declares none (null) and a static one is padded, never truncated —
/// a longer input fails with `EmbeddingInputTooLongException`.
///
/// Apps get it through `FlutterEdgeAi.getActiveEmbedder()`. Driven directly
/// (tests, device gates), follow the `EmbeddingPass` lifecycle: [load] once,
/// [embed], then [close] — also after a failed [load], which is what frees a
/// session the load had already opened. NOT shareable across isolates: the
/// session belongs to the isolate that loaded it.
final class OnnxEmbeddingPass extends TokenEmbeddingPass {
  /// [clientFactory] substitutes the ORT session (a fake in unit tests); the
  /// default is the `dart:ffi` client over the bundled ONNX Runtime.
  OnnxEmbeddingPass(
    OnnxEmbeddingConfig config, {
    OrtClient Function()? clientFactory,
  }) : _modelPath = config.modelPath,
       _clientFactory = clientFactory ?? OrtFfiClient.new,
       super(
         tokenizerPath: config.tokenizerPath,
         tokenizerFactory: config.tokenizerFactory,
       );

  final String _modelPath;
  final OrtClient Function() _clientFactory;

  OrtClient? _client;
  OrtIoSpec? _spec;

  @override
  Future<TokenPassGraph> openGraph() async {
    final client = _clientFactory();
    // Held before the session opens, so closeGraph frees it whatever fails
    // after this — the load itself, or the dimension probe after it.
    _client = client;
    final spec = await client.load(_modelPath);
    _spec = spec;
    return describeOrtGraph(client, spec, _modelPath);
  }

  @override
  Future<ForwardResult> runTokens(TokenizedInput input) async {
    final client = _client;
    final spec = _spec;
    if (client == null || spec == null) {
      throw StateError('OnnxEmbeddingPass ran without an open session');
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
