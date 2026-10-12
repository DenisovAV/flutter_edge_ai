// The web `OnnxEmbeddingBackend`: what describe() wires into the pass. The pass
// itself is pure Dart and tested on the VM with a fake resolver and client
// (onnx_web_embedding_pass_test.dart); only here, in a browser, can a test see
// that the backend hands it the REAL ones — `resolveWebModelUrl`, which turns a
// streaming-mode `opfs://` path into a `blob:` URL, and `OrtWebClient`.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/onnx_embedding_backend_web_test.dart
@TestOn('browser')
library;

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;
import 'package:flutter_edge_ai_onnx/src/web/onnx_embedding_backend_web.dart';
import 'package:flutter_edge_ai_onnx/src/web/onnx_web_embedding_pass.dart';
import 'package:flutter_edge_ai_onnx/src/web/ort_web_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _minilm = EmbeddingModelSpec(
  name: 'minilm',
  modelSource: ModelSource.network('https://example.com/model.onnx'),
  tokenizerSource: ModelSource.network('https://example.com/tokenizer.json'),
);

RuntimeConfig _config({bool supportImage = false}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: 'opfs://model.onnx',
  tokenizerPath: 'opfs://tokenizer.json',
  supportImage: supportImage,
);

void main() {
  const backend = OnnxEmbeddingBackend();

  setUp(
    () => EmbeddingTokenizerRegistry.instance.registerAll([_AnyTokenizer()]),
  );
  tearDown(EmbeddingTokenizerRegistry.instance.reset);

  test('claims .onnx/.ort, ASCII case-insensitive', () {
    expect(backend.canHandle(_minilm), isTrue);
    expect(
      backend.canHandle(
        EmbeddingModelSpec(
          name: 'upper',
          modelSource: ModelSource.network('https://example.com/MODEL.ORT'),
          tokenizerSource: ModelSource.network('https://example.com/t.json'),
        ),
      ),
      isTrue,
    );
  });

  test('describe() wires resolveWebModelUrl and OrtWebClient into the pass, '
      'with the raw (opfs://) paths left for the pass to resolve', () async {
    final descriptor = await backend.describe(_minilm, _config());
    final config = descriptor.config as OnnxWebEmbeddingConfig;

    expect(config.modelPath, 'opfs://model.onnx');
    expect(config.tokenizerPath, 'opfs://tokenizer.json');
    expect(config.resolveUrl == resolveWebModelUrl, isTrue);
    expect(config.revokeUrl == revokeObjectUrl, isTrue);
    expect(config.clientFactory(), isA<OrtWebClient>());
    expect(config.tokenizerFactory == _unused, isTrue);
    expect(descriptor.activeBackend, isNull, reason: 'unknown, never CPU');
    expect(descriptor.build(), isA<OnnxWebEmbeddingPass>());
  });

  test('describe() refuses declared media', () async {
    await expectLater(
      backend.describe(_minilm, _config(supportImage: true)),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          'ONNX embeddings are text-only',
        ),
      ),
    );
  });
}

final class _AnyTokenizer implements EmbeddingTokenizerProvider {
  @override
  String get name => 'any';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  EmbeddingTokenizerFactory get factory => _unused;
}

Future<EmbeddingTokenizer> _unused(String _) =>
    throw UnimplementedError('describe() tests never tokenize');
