// `LiteRtEmbeddingBackend` (native arm): what it claims, how describe() routes
// on the file core opens, what it refuses, and what it hands core. describe()
// is pure, so every test inspects a descriptor and nothing spawns a worker or
// opens a native library.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_npu.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/weight_cache_notice.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart' show NpuVendor;
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
    File(
      '$bundles/eg2_ptl.litertlm',
    ).writeAsBytesSync(eg2Container(textStamp: ('IntelOpenVINO', 'PTL')));
    File('$bundles/eg2_npu_audio.litertlm').writeAsBytesSync(
      eg2Container(
        textStamp: ('Qualcomm', 'SM8850'),
        vision: true,
        audio: true,
      ),
    );
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

    test('requireWeightCache is off by default and reaches the pass when '
        'set', () async {
      final lenient = await backend.describe(
        _bundle(),
        _config('$bundles/eg2.litertlm'),
      );
      expect(
        (lenient.config as LiteRtLmEmbeddingConfig).requireWeightCache,
        isFalse,
      );
      final strict = await const LiteRtEmbeddingBackend(
        requireWeightCache: true,
      ).describe(_bundle(), _config('$bundles/eg2.litertlm'));
      expect(
        (strict.config as LiteRtLmEmbeddingConfig).requireWeightCache,
        isTrue,
      );
      expect(strict.activeBackend, PreferredBackend.cpu);
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

  group('requireWeightCache where it cannot apply is said once per isolate, '
      'in debug builds', () {
    const strict = LiteRtEmbeddingBackend(requireWeightCache: true);
    late List<String> logged;
    late DebugPrintCallback original;

    setUp(() {
      resetRequireWeightCacheNotice();
      logged = [];
      original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
    });
    tearDown(() {
      debugPrint = original;
      edgeAiLogLevel = EdgeAiLogLevel.info;
      resetRequireWeightCacheNotice();
    });

    Iterable<String> notices() =>
        logged.where((line) => line.contains('requireWeightCache'));

    Future<void> describeTflite(LiteRtEmbeddingBackend b) => b.describe(
      _tflite(),
      _config('/data/gemma.tflite', tokenizerPath: '/data/t.model'),
    );

    Future<void> describeNpu(
      LiteRtEmbeddingBackend b, {
      String model = 'eg2_npu.litertlm',
      bool supportAudio = false,
    }) => b.describe(
      _bundle(model: model),
      _config(
        '$bundles/$model',
        preferredBackend: PreferredBackend.npu,
        supportAudio: supportAudio,
      ),
    );

    test('a .tflite embedder: said once, however many loads', () async {
      await describeTflite(strict);
      await describeTflite(strict);
      expect(notices(), [
        allOf(
          contains('does not apply to this load'),
          contains('gemma.tflite'),
          contains('.tflite'),
        ),
      ]);
    });

    test('an NPU load without declared audio is said; a CPU load, an NPU '
        'load with declared audio and the flag off say nothing', () async {
      liteRtLmNpuHost = _QualcommAndroid();
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());

      await strict.describe(_bundle(), _config('$bundles/eg2.litertlm'));
      await describeNpu(
        strict,
        model: 'eg2_npu_audio.litertlm',
        supportAudio: true,
      );
      await describeNpu(backend);
      await describeTflite(backend);
      expect(notices(), isEmpty);

      await describeNpu(strict);
      expect(notices(), [
        allOf(
          contains('does not apply to this load'),
          contains('eg2_npu.litertlm'),
          contains('NPU'),
        ),
      ]);
    });

    test('with logging off the one shot is not spent: raised later, the line '
        'still comes', () async {
      edgeAiLogLevel = EdgeAiLogLevel.none;
      await describeTflite(strict);
      expect(notices(), isEmpty);
      edgeAiLogLevel = EdgeAiLogLevel.info;
      await describeTflite(strict);
      expect(notices(), hasLength(1));
    });
  });

  group('describe() places the bundle from its own bytes: CPU or its NPU, '
      'never a switch', () {
    test('the generic bundle runs on CPU for every request but npu, on a '
        'host without GPU embeddings', () async {
      // Pinned: on a Windows or Linux x64 runner gpu goes to the GPU (the
      // GPU group below).
      liteRtLmNpuHost = _QualcommAndroid();
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());
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
      'a Qualcomm per-SoC bundle with npu on this host is refused unless the '
      'host is Qualcomm Android or Linux arm64',
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
              contains(
                Abi.current() == Abi.windowsX64
                    ? 'runs Intel NPU bundles only'
                    : 'Qualcomm Android and Qualcomm Linux arm64, and on Google '
                          'Tensor G5/G6 Android devices, and on MediaTek Dimensity Android devices, and on Intel NPUs with '
                          'Windows x64, only',
              ),
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

    test('an Intel per-SoC bundle with npu on Windows x64 hands the pass its '
        'target and the directory beside the executable', () async {
      liteRtLmNpuHost = _IntelWindows();
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());
      final descriptor = await backend.describe(
        _bundle(model: 'eg2_ptl.litertlm'),
        _config(
          '$bundles/eg2_ptl.litertlm',
          preferredBackend: PreferredBackend.npu,
        ),
      );
      expect(descriptor.activeBackend, PreferredBackend.npu);
      final config = descriptor.config as LiteRtLmEmbeddingConfig;
      expect(
        config.npuTarget,
        const LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
      );
      expect(config.npuDispatchDir, r'C:\Apps\demo');
      expect(config.backend, PreferredBackend.npu);
    });

    test('an Intel per-SoC bundle with npu on Qualcomm Android is refused '
        'before the Qualcomm stack is prepared', () async {
      final host = _QualcommAndroid();
      liteRtLmNpuHost = host;
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());
      await expectLater(
        backend.describe(
          _bundle(model: 'eg2_ptl.litertlm'),
          _config(
            '$bundles/eg2_ptl.litertlm',
            preferredBackend: PreferredBackend.npu,
          ),
        ),
        _loadRefusal('LiteRT-LM', contains('Intel ones run on windows_x64')),
      );
      expect(host.prepared, isFalse);
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

  group('EmbeddingGemma 2 on the GPU (Windows and Linux x64, measured)', () {
    void hostIs(LiteRtLmNpuHost host) {
      liteRtLmNpuHost = host;
      addTearDown(() => liteRtLmNpuHost = const LiteRtLmPlatformNpuHost());
    }

    // eg2_text.litertlm is the 270m's shape: text encoder and embedder only.
    Future<EmbeddingPassDescriptor<Object>> describeGpu({
      LiteRtEmbeddingBackend b = backend,
      String model = 'eg2_text.litertlm',
      bool supportImage = false,
      bool supportAudio = false,
    }) => b.describe(
      _bundle(model: model),
      _config(
        '$bundles/$model',
        preferredBackend: PreferredBackend.gpu,
        supportImage: supportImage,
        supportAudio: supportAudio,
      ),
    );

    for (final host in [_IntelWindows(), _LinuxX64()]) {
      test('${host.abi}: a bundle honours gpu, a .tflite spec does not', () {
        hostIs(host);
        expect(backend.honouredBackends(_bundle()), {
          PreferredBackend.cpu,
          PreferredBackend.gpu,
          PreferredBackend.npu,
        });
        expect(backend.honouredBackends(_tflite()), {
          PreferredBackend.cpu,
          PreferredBackend.npu,
        });
      });

      test('${host.abi}: gpu hands the pass the GPU and declares it', () async {
        hostIs(host);
        final d = await describeGpu();
        final config = d.config as LiteRtLmEmbeddingConfig;
        expect(d.activeBackend, PreferredBackend.gpu);
        expect(config.gpu, isTrue);
        expect(config.backend, PreferredBackend.gpu);
        expect(config.npuTarget, isNull);
      });
    }

    test('elsewhere a bundle keeps the default and gpu runs on CPU', () async {
      hostIs(_QualcommAndroid());
      expect(backend.honouredBackends(_bundle()), {
        PreferredBackend.cpu,
        PreferredBackend.npu,
      });
      final d = await describeGpu();
      expect(d.activeBackend, PreferredBackend.cpu);
      expect((d.config as LiteRtLmEmbeddingConfig).gpu, isFalse);
    });

    test('images on the GPU with the 270m are refused before the held '
        'embedder closes, naming the bundle with a vision encoder', () async {
      hostIs(_IntelWindows());
      await expectLater(
        describeGpu(supportImage: true),
        _loadRefusal(
          'LiteRT-LM',
          allOf(
            contains('has no vision encoder'),
            contains('embeddinggemma-2-text-vision-440m'),
            isNot(contains('preferredBackend: cpu')),
          ),
        ),
      );
    });

    test('a bundle with vision or audio towers runs its text tower on the '
        'GPU and names each present tower cpu, declared or not', () async {
      hostIs(_IntelWindows());
      for (final (model, image, audio, vision, audioTower) in [
        ('eg2_text.litertlm', false, false, false, false),
        ('eg2.litertlm', false, false, true, false),
        ('eg2.litertlm', true, false, true, false),
        ('eg2_audio.litertlm', false, false, true, true),
        ('eg2_audio.litertlm', true, true, true, true),
      ]) {
        final d = await describeGpu(
          model: model,
          supportImage: image,
          supportAudio: audio,
        );
        final config = d.config as LiteRtLmEmbeddingConfig;
        final reason = '$model image=$image audio=$audio';
        expect(d.activeBackend, PreferredBackend.gpu, reason: reason);
        expect(config.gpu, isTrue, reason: reason);
        expect(config.visionTowerOnCpu, vision, reason: reason);
        expect(config.audioTowerOnCpu, audioTower, reason: reason);
      }
    });

    test('a CPU load names no tower', () async {
      final d = await backend.describe(
        _bundle(model: 'eg2_audio.litertlm'),
        _config('$bundles/eg2_audio.litertlm', supportAudio: true),
      );
      final config = d.config as LiteRtLmEmbeddingConfig;
      expect(config.visionTowerOnCpu, isFalse);
      expect(config.audioTowerOnCpu, isFalse);
    });

    test('on the real headers: the 270m has no media tower, the 440m a vision '
        'tower, the 740m vision and audio', () {
      expect(readLiteRtLmMediaTowers(_header270m), (
        vision: false,
        audio: false,
      ));
      expect(readLiteRtLmMediaTowers(_header440m), (
        vision: true,
        audio: false,
      ));
      expect(readLiteRtLmMediaTowers(_header740m), (vision: true, audio: true));
    });

    test('an unreadable container on the GPU is a load failure naming the '
        'towers it looked for', () async {
      hostIs(_IntelWindows());
      File('$bundles/garbage.litertlm').writeAsBytesSync(List.filled(64, 1));
      await expectLater(
        describeGpu(model: 'garbage.litertlm'),
        throwsA(isA<EmbeddingLoadException>()),
      );
      expect(
        () => readLiteRtLmMediaTowers('$bundles/garbage.litertlm'),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            contains('its vision and audio towers'),
          ),
        ),
      );
    });

    test(
      'a per-SoC bundle with gpu is still refused: it runs on its NPU',
      () async {
        hostIs(_IntelWindows());
        await expectLater(
          describeGpu(model: 'eg2_ptl.litertlm'),
          throwsA(isA<EmbeddingLoadException>()),
        );
      },
    );

    test(
      'requireWeightCache on the GPU applies (the pass checks ML Drift\'s '
      'caches): no not-applied notice, and the flag reaches the pass',
      () async {
        hostIs(_LinuxX64());
        resetRequireWeightCacheNotice();
        final logged = <String>[];
        final original = debugPrint;
        debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
        addTearDown(() {
          debugPrint = original;
          resetRequireWeightCacheNotice();
        });
        const strict = LiteRtEmbeddingBackend(requireWeightCache: true);
        final d = await describeGpu(b: strict);
        final config = d.config as LiteRtLmEmbeddingConfig;
        expect(config.gpu, isTrue);
        expect(config.requireWeightCache, isTrue);
        expect(
          logged.where((line) => line.contains('requireWeightCache')),
          isEmpty,
        );
      },
    );
  });
}

/// A Linux x64 desktop: no NPU vendor runs there, so nothing may be asked.
final class _LinuxX64 implements LiteRtLmNpuHost {
  @override
  String get operatingSystem => 'linux';
  @override
  String get abi => 'linux_x64';
  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) async =>
      throw StateError('linux_x64 has no NPU stack to ask about');
  @override
  String? unreachable(NpuVendor vendor) =>
      throw StateError('linux_x64 has no NPU to probe');
  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) async =>
      throw StateError('linux_x64 has no NPU dispatch');
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
  bool prepared = false;
  @override
  String get operatingSystem => 'android';
  @override
  String get abi => 'android_arm64';
  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) async => switch (vendor) {
    NpuVendor.qualcomm => const NpuStackCheck.bundled(),
    NpuVendor.googleTensor || NpuVendor.mediatek => throw StateError(
      'this fake is specifically a Qualcomm Android phone',
    ),
    NpuVendor.intel => throw StateError(
      'an Android host has no Intel stack to ask about',
    ),
  };
  @override
  String? unreachable(NpuVendor vendor) => null;
  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) async {
    prepared = true;
    return '/data/app/npu';
  }
}

/// A Windows x64 PC: its build carries the Intel stack beside the executable.
final class _IntelWindows implements LiteRtLmNpuHost {
  @override
  String get operatingSystem => 'windows';
  @override
  String get abi => 'windows_x64';
  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) async => switch (vendor) {
    NpuVendor.intel => const NpuStackCheck.bundled(),
    NpuVendor.qualcomm => throw StateError(
      'a Windows host has no Qualcomm stack to ask about',
    ),
    NpuVendor.googleTensor => throw StateError(
      'a Windows host has no Google Tensor stack to ask about',
    ),
    NpuVendor.mediatek => throw StateError(
      'a Windows host has no MediaTek stack to ask about',
    ),
  };
  @override
  String? unreachable(NpuVendor vendor) =>
      vendor == NpuVendor.intel ? null : 'not this host';
  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) async => r'C:\Apps\demo';
}
