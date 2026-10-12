// `LiteRtEmbeddingBackend` (native arm): what it claims, how describe() routes
// on the file core opens, what it refuses, and what it hands core. describe()
// is pure, so every test inspects a descriptor and nothing spawns a worker or
// opens a native library.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_npu.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'litertlm_container_fixture.dart';

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
  PreferredBackend? preferredBackend,
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: modelPath,
  tokenizerPath: tokenizerPath,
  supportImage: supportImage,
  supportAudio: supportAudio,
  preferredBackend: preferredBackend,
);

/// Container headers of the real bundles (test/ffi/fixtures/README.md).
const _header270m = 'test/ffi/fixtures/embeddinggemma2_270m_header.litertlm';
const _header440m = 'test/ffi/fixtures/embeddinggemma2_440m_header.litertlm';
const _header740m = 'test/ffi/fixtures/embeddinggemma2_740m_header.litertlm';

Matcher _loadRefusal(String engine, Object message) => throwsA(
  isA<EmbeddingLoadException>()
      .having((e) => e.engine, 'engine', engine)
      .having((e) => e.message, 'message', message),
);

/// path_provider's channel, as `flutter test` reaches it (no plugin
/// registration in a host test).
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

/// Where the bundles describe() reads live: describe() reads the first KB of
/// a `.litertlm` to tell a per-SoC NPU bundle from the generic one.
late String bundles;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = LiteRtEmbeddingBackend();
  late _CountingTokenizers tokenizers;
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('litert_backend_test_');
    bundles = root.path;
    final generic = eg2Container(vision: true);
    File('$bundles/eg2.litertlm').writeAsBytesSync(generic);
    File('$bundles/EG2.LITERTLM').writeAsBytesSync(generic);
    File('$bundles/eg2_text.litertlm').writeAsBytesSync(eg2Container());
    File(
      '$bundles/eg2_audio.litertlm',
    ).writeAsBytesSync(eg2Container(vision: true, audio: true));
    File(
      '$bundles/eg2_npu.litertlm',
    ).writeAsBytesSync(eg2Container(textStamp: ('Qualcomm', 'SM8850')));
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
    root.deleteSync(recursive: true);
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
          _config('$bundles/eg2.litertlm'),
        );
        expect(descriptor.engineTag, 'LiteRT-LM');
        expect(descriptor.activeBackend, PreferredBackend.cpu);
        final config = descriptor.config as LiteRtLmEmbeddingConfig;
        expect(config.modelPath, '$bundles/eg2.litertlm');
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
      await backend.describe(_bundle(), _config('$bundles/eg2.litertlm'));
      expect(tokenizers.asked, 0);
    });

    test(
      'declared images reach the pass, with the default budget of 140; '
      'whether the bundle has a vision encoder is the pass\'s question',
      () async {
        final descriptor = await backend.describe(
          _bundle(),
          _config('$bundles/eg2.litertlm', supportImage: true),
        );
        final config = descriptor.config as LiteRtLmEmbeddingConfig;
        expect(config.declaredMedia, {EmbeddingModality.image});
        expect(config.visionTokensPerImage, 140);
        expect(descriptor.activeBackend, PreferredBackend.cpu);
        expect(tokenizers.asked, 0);
      },
    );

    test('visionTokensPerImage: 70 is the opt-in budget', () async {
      final descriptor =
          await const LiteRtEmbeddingBackend(visionTokensPerImage: 70).describe(
            _bundle(),
            _config('$bundles/eg2.litertlm', supportImage: true),
          );
      expect(
        (descriptor.config as LiteRtLmEmbeddingConfig).visionTokensPerImage,
        70,
      );
    });

    test('needs no tokenizer provider at all: an EG2-only app registers '
        'none', () async {
      EmbeddingTokenizerRegistry.instance.reset();
      final descriptor = await backend.describe(
        _bundle(),
        _config('$bundles/eg2.litertlm'),
      );
      expect(descriptor.config, isA<LiteRtLmEmbeddingConfig>());
    });
  });

  group('describe() places the bundle from its own bytes: CPU or its NPU, '
      'never a switch', () {
    test('the generic bundle runs on CPU for every request but npu', () async {
      for (final requested in [
        null,
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]) {
        final descriptor = await backend.describe(
          _bundle(),
          _config('$bundles/eg2.litertlm', preferredBackend: requested),
        );
        expect(descriptor.activeBackend, PreferredBackend.cpu);
        final config = descriptor.config as LiteRtLmEmbeddingConfig;
        expect(config.npuTarget, isNull);
        expect(config.npuDispatchDir, isNull);
        expect(config.backend, PreferredBackend.cpu);
      }
    });

    test('the generic bundle with npu is refused, naming the per-SoC '
        'bundles', () async {
      await expectLater(
        backend.describe(
          _bundle(),
          _config(
            '$bundles/eg2.litertlm',
            preferredBackend: PreferredBackend.npu,
          ),
        ),
        _loadRefusal(
          'LiteRT-LM',
          allOf(contains('generic EmbeddingGemma 2 bundle'), contains('NPU')),
        ),
      );
    });

    test('a per-SoC bundle without npu is refused — detected from its bytes, '
        'whatever its name', () async {
      // Named like a generic bundle on purpose: the name says nothing.
      File('$bundles/eg2_npu.litertlm').copySync('$bundles/plain.litertlm');
      for (final requested in [
        null,
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]) {
        await expectLater(
          backend.describe(
            _bundle(model: 'plain.litertlm'),
            _config('$bundles/plain.litertlm', preferredBackend: requested),
          ),
          _loadRefusal(
            'LiteRT-LM',
            allOf(
              contains('compiled for the Qualcomm SM8850 NPU'),
              contains('PreferredBackend.npu'),
            ),
          ),
        );
      }
    });

    test(
      'a per-SoC bundle with npu on this host is refused unless the host '
      'is Qualcomm Android or Linux arm64',
      () async {
        await expectLater(
          backend.describe(
            _bundle(model: 'eg2_npu.litertlm'),
            _config(
              '$bundles/eg2_npu.litertlm',
              preferredBackend: PreferredBackend.npu,
            ),
          ),
          _loadRefusal(
            'LiteRT-LM',
            allOf(
              contains('Qualcomm Android and Qualcomm Linux arm64 only'),
              contains('${Abi.current()}'),
            ),
          ),
        );
      },
      skip: '${Abi.current()}' == 'linux_arm64'
          ? 'a linux_arm64 host may have a Qualcomm NPU'
          : false,
    );

    test('a per-SoC bundle with npu where the NPU can run it hands the pass '
        'its target and dispatch directory, and declares npu', () async {
      liteRtLmNpuHost = _QualcommAndroid();
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());
      final descriptor = await backend.describe(
        _bundle(model: 'eg2_npu.litertlm'),
        _config(
          '$bundles/eg2_npu.litertlm',
          preferredBackend: PreferredBackend.npu,
          supportImage: true,
        ),
      );
      expect(descriptor.activeBackend, PreferredBackend.npu);
      final config = descriptor.config as LiteRtLmEmbeddingConfig;
      expect(
        config.npuTarget,
        const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
      );
      expect(config.npuDispatchDir, '/data/app/npu');
      expect(config.backend, PreferredBackend.npu);
      expect(config.declaredMedia, {EmbeddingModality.image});
      expect(config.cacheBase, '/cache/flutter_edge_ai/emb');
    });

    test('a bundle describe() cannot read is refused, not guessed', () async {
      await expectLater(
        backend.describe(
          _bundle(model: 'gone.litertlm'),
          _config('$bundles/gone.litertlm'),
        ),
        _loadRefusal('LiteRT-LM', startsWith('could not read gone.litertlm')),
      );
      File('$bundles/junk.litertlm').writeAsBytesSync(List.filled(64, 3));
      await expectLater(
        backend.describe(
          _bundle(model: 'junk.litertlm'),
          _config('$bundles/junk.litertlm'),
        ),
        _loadRefusal(
          'LiteRT-LM',
          startsWith('junk.litertlm is not a readable .litertlm bundle'),
        ),
      );
    });
  });

  group('visionTokensPerImage: 140 or 70, anything else refused in describe() '
      '(D25)', () {
    // Natively 200 and 280 fail to load, while 1, 35, 100 and 141 are
    // accepted SILENTLY and change the vectors (measured): refused in Dart.
    for (final budget in [0, -1, 1, 35, 69, 71, 100, 139, 141, 200, 280]) {
      test('$budget is refused, before routing and before the tokenizer '
          'registry', () async {
        final misconfigured = LiteRtEmbeddingBackend(
          visionTokensPerImage: budget,
        );
        await expectLater(
          misconfigured.describe(
            _bundle(),
            _config('$bundles/eg2.litertlm', supportImage: true),
          ),
          _loadRefusal(
            'LiteRT-LM',
            allOf(
              contains('visionTokensPerImage: $budget'),
              contains('140'),
              contains('70'),
            ),
          ),
        );
        // Text-only use and a .tflite model too: a backend configured with an
        // unsupported budget is refused wherever it is used, not first on the
        // day an image arrives.
        await expectLater(
          misconfigured.describe(_bundle(), _config('$bundles/eg2.litertlm')),
          throwsA(isA<EmbeddingLoadException>()),
        );
        await expectLater(
          misconfigured.describe(
            _tflite(),
            _config('/data/gemma.tflite', tokenizerPath: '/data/t.model'),
          ),
          _loadRefusal('LiteRT', contains('visionTokensPerImage: $budget')),
        );
        expect(tokenizers.asked, 0);
      });
    }
  });

  group('describe() routes on the file core opens', () {
    test('declared audio on a bundle with an audio encoder (the 740m\'s '
        'section types) reaches the pass, with or without images', () async {
      for (final image in [false, true]) {
        final descriptor = await backend.describe(
          _bundle(),
          _config(
            '$bundles/eg2_audio.litertlm',
            supportImage: image,
            supportAudio: true,
          ),
        );
        final config = descriptor.config as LiteRtLmEmbeddingConfig;
        expect(config.declaredMedia, {
          EmbeddingModality.audio,
          if (image) EmbeddingModality.image,
        });
        expect(descriptor.activeBackend, PreferredBackend.cpu);
      }
      expect(tokenizers.asked, 0);
    });

    test('declared audio on a bundle without an audio encoder (the 270m and '
        'the 440m, whose ModelInfo claims audio) is refused in describe(), '
        'naming the 740m — before core closes the embedder it holds', () async {
      for (final name in ['eg2_text.litertlm', 'eg2.litertlm']) {
        await expectLater(
          backend.describe(
            _bundle(),
            _config('$bundles/$name', supportAudio: true),
          ),
          _loadRefusal(
            'LiteRT-LM',
            '$name has no audio encoder; install embeddinggemma-2-740m',
          ),
        );
        // Text from the same bundle still describes: the audio check runs
        // only for declared audio.
        await backend.describe(_bundle(), _config('$bundles/$name'));
      }
    });

    test('on the real bundles\' headers the audio check reads the 740m as '
        'having an audio encoder and the 270m and the 440m as not', () {
      requireLiteRtLmAudioEncoder(_header740m);
      for (final header in [_header270m, _header440m]) {
        expect(
          () => requireLiteRtLmAudioEncoder(header),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              contains('has no audio encoder'),
            ),
          ),
        );
      }
    });

    test('declared audio on a container it cannot read is a load failure, '
        'never "no audio"', () async {
      await expectLater(
        backend.describe(
          _bundle(),
          _config('/data/missing.litertlm', supportAudio: true),
        ),
        _loadRefusal(
          'LiteRT-LM',
          startsWith('could not read the container of missing.litertlm'),
        ),
      );
    });

    test('a .tflite model with declared audio is still a text-only '
        'model', () async {
      await expectLater(
        backend.describe(
          _tflite(),
          _config(
            '/data/gemma.tflite',
            tokenizerPath: '/data/t.model',
            supportAudio: true,
          ),
        ),
        _loadRefusal('LiteRT', contains('text-only')),
      );
    });

    test('the suffix is matched without regard to case', () async {
      final descriptor = await backend.describe(
        _bundle(model: 'EG2.LITERTLM'),
        _config('$bundles/EG2.LITERTLM'),
      );
      expect(descriptor.config, isA<LiteRtLmEmbeddingConfig>());
      expect(tokenizers.asked, 0);
    });

    test('an opened file that disagrees with the spec is identity corrupt, '
        'both ways', () async {
      await expectLater(
        backend.describe(
          _tflite(),
          _config('$bundles/eg2.litertlm', tokenizerPath: '/data/t.model'),
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

/// A Qualcomm Android phone whose app bundled the NPU stack.
final class _QualcommAndroid implements LiteRtLmNpuHost {
  @override
  String get operatingSystem => 'android';
  @override
  String get abi => 'android_arm64';
  @override
  Future<NpuStackCheck> qualcommStack() async => const NpuStackCheck.bundled();
  @override
  bool get hasNpu => true;
  @override
  String get noNpuReason => '';
  @override
  Future<String> prepareDispatchDir() async => '/data/app/npu';
}
