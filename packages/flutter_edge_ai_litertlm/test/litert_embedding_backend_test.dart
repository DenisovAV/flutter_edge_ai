// `LiteRtEmbeddingBackend` (native arm): what it claims, how describe() routes
// on the file core opens, what it refuses, and what it hands core. describe()
// is pure, so every test inspects a descriptor and nothing spawns a worker or
// opens a native library.

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

EmbeddingModelSpec _tflite({String model = 'gemma.tflite'}) =>
    EmbeddingModelSpec(
      name: 'embeddinggemma',
      modelSource: ModelSource.file('/models/$model'),
      tokenizerSource: ModelSource.file('/models/t.model'),
    );

EmbeddingModelSpec _bundle({String model = 'eg2.litertlm'}) =>
    EmbeddingModelSpec(
      name: 'embeddinggemma-2',
      modelSource: ModelSource.file('/models/$model'),
    );

RuntimeConfig _config(
  String modelPath, {
  String? tokenizerPath,
  bool supportImage = false,
  bool supportAudio = false,
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: modelPath,
  tokenizerPath: tokenizerPath,
  supportImage: supportImage,
  supportAudio: supportAudio,
);

Matcher _loadRefusal(String engine, Object message) => throwsA(
  isA<EmbeddingLoadException>()
      .having((e) => e.engine, 'engine', engine)
      .having((e) => e.message, 'message', message),
);

/// path_provider's channel, as `flutter test` reaches it (no plugin
/// registration in a host test).
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = LiteRtEmbeddingBackend();
  late _CountingTokenizers tokenizers;

  setUp(() {
    tokenizers = _CountingTokenizers();
    EmbeddingTokenizerRegistry.instance.registerAll([tokenizers]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathProvider,
          (call) async => switch (call.method) {
            'getApplicationCacheDirectory' => '/cache',
            'getApplicationSupportDirectory' => '/support',
            _ => null,
          },
        );
  });
  tearDown(() {
    EmbeddingTokenizerRegistry.instance.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
  });

  test('identity', () {
    expect(backend.name, 'LiteRT Embedding');
    expect(backend.priority, 0);
  });

  group('canHandle', () {
    test('claims a two-file spec and a .litertlm bundle, any case', () {
      expect(backend.canHandle(_tflite()), isTrue);
      expect(backend.canHandle(_bundle()), isTrue);
      expect(backend.canHandle(_bundle(model: 'EG2.LiteRTLM')), isTrue);
    });
  });

  group('describe() on a .tflite spec', () {
    Future<EmbeddingPassDescriptor<Object>> describe({
      bool supportImage = false,
      bool supportAudio = false,
    }) => backend.describe(
      _tflite(),
      _config(
        '/data/gemma.tflite',
        tokenizerPath: '/data/t.model',
        supportImage: supportImage,
        supportAudio: supportAudio,
      ),
    );

    test('hands core the opened paths and the registry\'s tokenizer', () async {
      final descriptor = await describe();
      final config = descriptor.config as LiteRtEmbeddingConfig;
      expect(config.modelPath, '/data/gemma.tflite');
      expect(config.tokenizerPath, '/data/t.model');
      expect(
        identical(config.tokenizerFactory, _tokenize),
        isTrue,
        reason: 'the tokenizer is asked for, not named',
      );
      expect(descriptor.engineTag, 'LiteRT');
    });

    test('declares CPU, so EmbeddingModel.activeBackend is not null', () async {
      // The only place LiteRT's answer comes from. Delete it and
      // `getActiveEmbedder(preferredBackend:)` is unanswerable again in the one
      // build where the debug notice does not exist.
      expect((await describe()).activeBackend, PreferredBackend.cpu);
    });

    test('builds the .tflite pass', () async {
      expect((await describe()).build(), isA<LiteRtEmbeddingPass>());
    });

    test('refuses declared images or audio: the model is text-only', () async {
      for (final (image, audio) in [(true, false), (false, true)]) {
        await expectLater(
          describe(supportImage: image, supportAudio: audio),
          _loadRefusal('LiteRT', 'gemma.tflite is a text-only model'),
        );
      }
    });
  });

  group('describe() on a .litertlm bundle', () {
    test(
      'hands core the EmbeddingGemma 2 pass: the opened file, the '
      'engine-owned cache base in the platform cache directory, CPU',
      () async {
        final descriptor = await backend.describe(
          _bundle(),
          _config('/data/eg2.litertlm'),
        );
        expect(descriptor.engineTag, 'LiteRT-LM');
        expect(descriptor.activeBackend, PreferredBackend.cpu);
        final config = descriptor.config as LiteRtLmEmbeddingConfig;
        expect(config.modelPath, '/data/eg2.litertlm');
        // The platform cache directory, never application support: iOS backs
        // that up to iCloud and Android Auto Backup caps it at 25 MB per app,
        // while a purged cache is rebuilt at the next engine create.
        expect(config.cacheBase, '/cache/flutter_edge_ai/emb');
        expect(config.declaredMedia, isEmpty);
        expect(config.numThreads, isNull);
        expect(descriptor.build(), isA<LiteRtLmEmbeddingPass>());
      },
    );

    test('never asks the tokenizer registry', () async {
      await backend.describe(_bundle(), _config('/data/eg2.litertlm'));
      expect(tokenizers.asked, 0);
    });

    test('needs no tokenizer provider at all: an EG2-only app registers '
        'none', () async {
      EmbeddingTokenizerRegistry.instance.reset();
      final descriptor = await backend.describe(
        _bundle(),
        _config('/data/eg2.litertlm'),
      );
      expect(descriptor.config, isA<LiteRtLmEmbeddingConfig>());
    });
  });

  group('describe() routes on the file core opens', () {
    test(
      'a .litertlm bundle with declared media gets the 1.13.0 refusal',
      () async {
        for (final (image, audio) in [(true, false), (false, true)]) {
          await expectLater(
            backend.describe(
              _bundle(),
              _config(
                '/data/eg2.litertlm',
                supportImage: image,
                supportAudio: audio,
              ),
            ),
            _loadRefusal(
              'LiteRT-LM',
              'flutter_edge_ai_litertlm 1.13.0 embeds text only; images arrive '
                  'in 1.14.0, audio in 1.16.0',
            ),
          );
        }
        expect(tokenizers.asked, 0);
      },
    );

    test('the suffix is matched without regard to case', () async {
      final descriptor = await backend.describe(
        _bundle(model: 'EG2.LITERTLM'),
        _config('/data/EG2.LITERTLM'),
      );
      expect(descriptor.config, isA<LiteRtLmEmbeddingConfig>());
      expect(tokenizers.asked, 0);
    });

    test('an opened file that disagrees with the spec is identity corrupt, '
        'both ways', () async {
      await expectLater(
        backend.describe(
          _tflite(),
          _config('/data/eg2.litertlm', tokenizerPath: '/data/t.model'),
        ),
        _loadRefusal('LiteRT-LM', startsWith('identity corrupt')),
      );
      await expectLater(
        backend.describe(_bundle(), _config('/data/gemma.tflite')),
        _loadRefusal('LiteRT', startsWith('identity corrupt')),
      );
      expect(tokenizers.asked, 0);
    });

    test('a .tflite spec with no resolved tokenizer path is identity '
        'corrupt', () async {
      await expectLater(
        backend.describe(_tflite(), _config('/data/gemma.tflite')),
        _loadRefusal('LiteRT', startsWith('identity corrupt')),
      );
    });
  });
}

/// Counts every time an engine asks for a tokenizer.
final class _CountingTokenizers implements EmbeddingTokenizerProvider {
  int asked = 0;

  @override
  String get name => 'counting';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) {
    asked++;
    return true;
  }

  @override
  EmbeddingTokenizerFactory get factory => _tokenize;
}

Future<EmbeddingTokenizer> _tokenize(String _) =>
    throw UnimplementedError('describe() tests never tokenize');
