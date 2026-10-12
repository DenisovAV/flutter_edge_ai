// `OnnxEmbeddingBackend` (native arm): identity, the `.onnx`/`.ort`
// `canHandle` matrix, and what describe() hands core or refuses. describe() is
// pure, so nothing here opens a session or spawns a worker.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_backend.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

EmbeddingModelSpec _spec(String modelFilename) => EmbeddingModelSpec(
  name: 'test-$modelFilename',
  modelSource: FileSource('/tmp/$modelFilename'),
  tokenizerSource: FileSource('/tmp/tokenizer.json'),
);

RuntimeConfig _config({
  String? tokenizerPath = '/data/tokenizer.json',
  bool supportImage = false,
  bool supportAudio = false,
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: '/data/model.onnx',
  tokenizerPath: tokenizerPath,
  supportImage: supportImage,
  supportAudio: supportAudio,
);

Matcher _loadRefusal(Object message) => throwsA(
  isA<EmbeddingLoadException>()
      .having((e) => e.engine, 'engine', 'ONNX')
      .having((e) => e.message, 'message', message),
);

void main() {
  const backend = OnnxEmbeddingBackend();

  test('identity: "ONNX Embedding", priority 10 (above LiteRT\'s 0)', () {
    expect(backend.name, 'ONNX Embedding');
    expect(backend.priority, 10);
  });

  group('canHandle extension matrix', () {
    test('handles .onnx and .ort, ASCII case-insensitive', () {
      for (final name in [
        'model.onnx',
        'model.ort',
        'MODEL.ONNX',
        'model.Onnx',
        'model.ORT',
      ]) {
        expect(backend.canHandle(_spec(name)), isTrue, reason: name);
      }
    });

    test('does not handle .tflite, .litertlm or an unrecognised name', () {
      for (final name in [
        'model.tflite',
        'model',
        'model.bin',
        'model.onnx.bin',
        'modelonnx',
      ]) {
        expect(backend.canHandle(_spec(name)), isFalse, reason: name);
      }
      expect(
        backend.canHandle(
          EmbeddingModelSpec(
            name: 'eg2',
            modelSource: FileSource('/tmp/model.litertlm'),
          ),
        ),
        isFalse,
      );
    });
  });

  group('describe()', () {
    setUp(
      () => EmbeddingTokenizerRegistry.instance.registerAll([_AnyTokenizer()]),
    );
    tearDown(() {
      EmbeddingTokenizerRegistry.instance.reset();
      OnnxEmbeddingBackend.debugForceUnsupportedHost = null;
    });

    test('hands core the opened paths, the registry\'s tokenizer and an '
        'OnnxEmbeddingPass', () async {
      final descriptor = await backend.describe(_spec('model.onnx'), _config());
      final config = descriptor.config as OnnxEmbeddingConfig;

      expect(descriptor.engineTag, 'ONNX');
      expect(config.modelPath, '/data/model.onnx');
      expect(config.tokenizerPath, '/data/tokenizer.json');
      expect(identical(config.tokenizerFactory, _unused), isTrue);
      expect(descriptor.build(), isA<OnnxEmbeddingPass>());
    });

    test('declares CPU, so EmbeddingModel.activeBackend is not null', () async {
      // No ORT client appends an execution provider, so CPU is the true
      // answer — and this line is the only place it comes from.
      final descriptor = await backend.describe(_spec('model.onnx'), _config());
      expect(descriptor.activeBackend, PreferredBackend.cpu);
    });

    test(
      'refuses declared images or audio: ONNX embeddings are text-only',
      () async {
        for (final (image, audio) in [(true, false), (false, true)]) {
          await expectLater(
            backend.describe(
              _spec('model.onnx'),
              _config(supportImage: image, supportAudio: audio),
            ),
            _loadRefusal('ONNX embeddings are text-only'),
          );
        }
      },
    );

    test(
      'a spec with no resolved tokenizer path is identity corrupt',
      () async {
        await expectLater(
          backend.describe(_spec('model.onnx'), _config(tokenizerPath: null)),
          _loadRefusal(startsWith('identity corrupt')),
        );
      },
    );

    test('canHandle stays true on an unsupported host — gating it would let '
        'another backend claim the file and fail obscurely — and describe() '
        'refuses there, naming the platform', () async {
      OnnxEmbeddingBackend.debugForceUnsupportedHost = true;

      expect(backend.canHandle(_spec('model.onnx')), isTrue);
      await expectLater(
        backend.describe(_spec('model.onnx'), _config()),
        _loadRefusal(
          allOf(contains('unsupported host'), contains('macOS-arm64')),
        ),
      );
    });
  });
}

/// Claims every spec. The factory is never called — these tests inspect the
/// descriptor, they do not spawn a worker.
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
    throw UnimplementedError('descriptor tests never tokenize');
