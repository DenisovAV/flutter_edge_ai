// Engine.create on the VM: a synthetic .litertlm on disk, the real bundle
// reader and load plan, and a fake EngineHost in place of the NPU probes and
// the native engine create. It holds what the runtime decides before LiteRT-LM
// is called: the context floor, the GPU activation rules, the encoders, the
// speculative decoding mode, the thread count, the NPU dispatch, and one
// create at a time.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

typedef _Create = ({
  String backend,
  int? maxTokens,
  BenchmarkTokens? benchmarkTokens,
  bool enableVision,
  String visionBackend,
  bool enableAudio,
  String audioBackend,
  bool? enableSpeculativeDecoding,
  int? speculativeDecodingMode,
  int? numThreads,
  int? activationDataType,
  GpuActivationReason? gpuActivationReason,
  NpuDispatch? npuDispatch,
});

/// A client whose conversations are fakes: one create can fail, a send on
/// one fails (it has no native conversation), and [shutdowns] counts closes.
class _BenchClient extends LiteRtLmFfiClient {
  _BenchClient({this.failCreate = false});

  final bool failCreate;
  int shutdowns = 0;
  int conversations = 0;

  @override
  BundleSampler get bundleSampler => const BundleSampler();

  @override
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    required Sampler sampling,
    required bool samplingExplicit,
    int? maxOutputTokens,
    required MediaOrder multimodalOrder,
    Constraint? constraint,
    ConversationExtras extras = ConversationExtras.none,
    required bool filterChannelContent,
  }) async {
    if (failCreate) throw StateError('no conversation');
    conversations++;
    return LiteRtLmConversationHandle.forTest(this);
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
    await super.shutdown();
  }
}

class _Host extends EngineHost implements LiteRtLmNpuHost {
  _Host({
    this.abiName = 'macos_arm64',
    this.npuShips = false,
    this.client,
    this.outsideFlutter = false,
  });

  final String abiName;
  final bool npuShips;

  /// False by default: the backend rules below are those of a Flutter app.
  /// A plain Dart program runs on the CPU only (the test of that).
  @override
  final bool outsideFlutter;

  /// The client every create gets; null: a fresh real one.
  final LiteRtLmFfiClient? client;

  @override
  LiteRtLmFfiClient createClient() => client ?? super.createClient();
  final creates = <_Create>[];
  final nativeLevels = <LiteRtLmLogLevel?>[];
  final prepared = <NpuStack>[];
  int creating = 0;
  int mostAtOnce = 0;

  /// Thrown by [initializeClient], as a library that does not load is.
  Object? initializeError;

  @override
  String get abi => abiName;

  @override
  String get operatingSystem => abiName.split('_').first;

  @override
  LiteRtLmNpuHost npuHost(NpuPlatform? platform) => this;

  @override
  Future<NpuStackCheck> stack(NpuStack vendor) async =>
      const NpuStackCheck.bundled();

  @override
  String? unreachable(NpuStack vendor) => npuShips ? null : 'no NPU here';

  @override
  Future<String> prepareDispatchDir(NpuStack vendor) async {
    prepared.add(vendor);
    return '/prepared/${vendor.name}';
  }

  @override
  Future<bool?> linearAttentionState(String path) async => false;

  @override
  Future<void> initializeClient(
    LiteRtLmFfiClient client, {
    required String modelPath,
    required String backend,
    required int? maxTokens,
    int? contextWindow,
    required String? cacheDir,
    required bool enableVision,
    required String visionBackend,
    required int maxNumImages,
    required bool enableAudio,
    required String audioBackend,
    required bool? enableSpeculativeDecoding,
    required int? speculativeDecodingMode,
    required int? numThreads,
    required int? activationDataType,
    required GpuActivationReason? gpuActivationReason,
    required NpuDispatch? npuDispatch,
    required LiteRtLmLogLevel? nativeLogLevel,
    BenchmarkTokens? benchmarkTokens,
  }) async {
    if (initializeError case final e?) throw e;
    nativeLevels.add(nativeLogLevel);
    mostAtOnce = max(mostAtOnce, ++creating);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    creating--;
    creates.add((
      backend: backend,
      maxTokens: maxTokens,
      benchmarkTokens: benchmarkTokens,
      enableVision: enableVision,
      visionBackend: visionBackend,
      enableAudio: enableAudio,
      audioBackend: audioBackend,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      speculativeDecodingMode: speculativeDecodingMode,
      numThreads: numThreads,
      activationDataType: activationDataType,
      gpuActivationReason: gpuActivationReason,
      npuDispatch: npuDispatch,
    ));
  }
}

/// A text model (with the `backend_constraint` [text]), the two encoders
/// (vision declaring [vision]), an `LlmMetadata` naming [family] (the
/// `llm_model_type` oneof case: gemma4 = 8, function_gemma = 3), and a text
/// model stamped for [npu] when given.
Uint8List _bundle({
  String? text,
  String? vision,
  int? family,
  int? maxNumTokens,
  (String, String)? npu,
}) => litertlmContainer(
  [
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_prefill_decode',
      bytes: tfliteModel({
        if (npu != null) 'LiteRtStamp': liteRtStamp(npu.$1, npu.$2),
      }),
    ),
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_vision_encoder',
      bytes: tfliteModel({}),
    ),
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_audio_encoder_hw',
      bytes: tfliteModel({}),
    ),
    if (family != null || maxNumTokens != null)
      (
        type: 5,
        modelType: null,
        bytes: [
          if (maxNumTokens != null) ...[0x28, ..._varint(maxNumTokens)],
          if (family != null) ...[0x32, 2, (family << 3) | 2, 0],
        ],
      ),
  ],
  items: {
    0: {'backend_constraint': ?text},
    1: {'backend_constraint': ?vision},
  },
);

List<int> _varint(int value) {
  final bytes = <int>[];
  var v = value;
  while (v >= 0x80) {
    bytes.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  return bytes..add(v);
}

void main() {
  late Directory dir;
  late _Host host;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('engine_create');
    host = _Host();
    debugEngineHost = host;
  });
  tearDown(() {
    debugEngineHost = null;
    dir.deleteSync(recursive: true);
  });

  String write(String name, Uint8List bytes) {
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return file.path;
  }

  Future<Engine> create(
    String path, {
    Backend? backend,
    Backend? visionBackend,
    Backend? audioBackend,
    int? maxNumTokens,
    ActivationDataType? activation,
    SpeculativeDecodingMode? speculative,
  }) => Engine.create(
    EngineConfig(
      modelPath: path,
      backend: backend,
      visionBackend: visionBackend,
      audioBackend: audioBackend,
      maxNumTokens: maxNumTokens,
      activationDataType: activation,
      speculativeDecoding: speculative,
    ),
  );

  test(
    'a libLiteRtLm the load path marks as not loaded, or not a build this '
    'release drives, is a LiteRtLmLibraryException; a refused setter, an '
    'isolate that did not spawn and a bad argument keep their types',
    () async {
      final generic = write('g.litertlm', _bundle());
      for (final error in <Object>[
        Exception('Failed to load libLiteRtLm.so with RTLD_GLOBAL'),
        ArgumentError('Failed to load dynamic library LiteRtLm.framework'),
        StateError('libLiteRtLm is not C API 1.x'),
        UnsupportedError('LiteRT-LM did not load on macOS'),
      ]) {
        host.initializeError = markLibraryLoadFailure(error);
        await expectLater(
          create(generic),
          throwsA(
            isA<LiteRtLmLibraryException>().having(
              (e) => e.message,
              'message',
              contains('$error'.split(': ').last),
            ),
          ),
          reason: '$error',
        );
      }
      host.initializeError = StateError('settings_set_num_threads failed');
      await expectLater(create(generic), throwsStateError);
      host.initializeError = IsolateSpawnException('out of memory');
      await expectLater(create(generic), throwsA(isA<IsolateSpawnException>()));
      host.initializeError = null;
      await expectLater(
        create(generic, backend: const Backend.cpu(threadCount: 0)),
        throwsArgumentError,
      );
    },
  );

  test('a load failure keeps its type for the adapter, marked', () {
    expect(markLibraryLoadFailure(ArgumentError('x')), isA<ArgumentError>());
    expect(markLibraryLoadFailure(StateError('x')), isA<StateError>());
    expect(markLibraryLoadFailure(Exception('x')), isA<Exception>());
    expect(
      markLibraryLoadFailure(UnsupportedError('x')),
      isA<UnsupportedError>(),
    );
    for (final e in [ArgumentError('x'), StateError('x'), Exception('x')]) {
      expect(markLibraryLoadFailure(e), isA<LibraryLoadFailure>());
    }
  });

  test(
    'the context floor applies to the CPU and the GPU, not the NPU',
    () async {
      final generic = write('g.litertlm', _bundle());
      final cpu = await create(generic, maxNumTokens: 256);
      final gpu = await create(
        generic,
        backend: const Backend.gpu(),
        maxNumTokens: 512,
      );
      host = _Host(abiName: 'android_arm64', npuShips: true);
      debugEngineHost = host;
      final npuFile = write('n.litertlm', _bundle(npu: ('Qualcomm', 'SM8750')));
      final npu = await create(
        npuFile,
        backend: Backend.npu(),
        maxNumTokens: 896,
      );
      expect(
        [cpu.maxNumTokens, gpu.maxNumTokens, npu.maxNumTokens],
        [1024, 1024, 896],
      );
      expect(host.creates.single.maxTokens, 896);
      for (final e in [cpu, gpu, npu]) {
        await e.close();
      }
    },
  );

  test('no maxNumTokens is left to LiteRT-LM: nothing is sent, and the '
      "engine's rules use the bundle's value, else 4096", () async {
    final declared = write('d.litertlm', _bundle(maxNumTokens: 2048));
    final none = write('n.litertlm', _bundle());
    final small = write('s.litertlm', _bundle(maxNumTokens: 512));
    final engines = [
      await create(declared),
      await create(none),
      await create(small),
      await create(declared, maxNumTokens: 2048),
    ];
    expect(engines.map((e) => e.maxNumTokens), [2048, 4096, 1024, 2048]);
    expect(host.creates.map((c) => c.maxTokens), [
      null,
      null,
      1024,
      2048,
    ], reason: 'a value below the #318 floor is raised and so sent');
    for (final e in engines) {
      await e.close();
    }
  });

  test("a GPU off Apple caps a bundle's context above 4096, as LiteRT-LM "
      'does; Apple keeps it', () async {
    final big = write('b.litertlm', _bundle(maxNumTokens: 32768));
    final mac = await create(big, backend: const Backend.gpu());
    host = _Host(abiName: 'android_arm64');
    debugEngineHost = host;
    final android = await create(big, backend: const Backend.gpu());
    final androidCpu = await create(big);
    expect(
      [mac.maxNumTokens, android.maxNumTokens, androidCpu.maxNumTokens],
      [32768, 4096, 32768],
    );
    expect(host.creates.map((c) => c.maxTokens), [null, null]);
    for (final e in [mac, android, androidCpu]) {
      await e.close();
    }
  });

  test('Gemma 4 with no maxNumTokens and none declared gets 4096, so a GPU '
      'load off Android runs float32', () async {
    final path = write('g4.litertlm', _bundle(family: 8));
    final gpu = await create(path, backend: const Backend.gpu());
    expect(gpu.maxNumTokens, 4096);
    expect(gpu.activationDataType, ActivationDataType.float32);
    expect(host.creates.single.maxTokens, isNull);
    await gpu.close();
  });

  test('a benchmark engine hands LiteRT-LM its token counts; Engine.create '
      'none', () async {
    final path = write('g.litertlm', _bundle());
    final plain = await create(path);
    final bench = await createBenchmarkEngine(EngineConfig(modelPath: path), (
      prefill: 256,
      decode: 128,
    ));
    expect(host.creates.map((c) => c.benchmarkTokens), [
      null,
      (prefill: 256, decode: 128),
    ]);
    // Timed from its turn: the fake create waits 10 ms.
    expect(bench.createTime, greaterThanOrEqualTo(Duration(milliseconds: 10)));
    await plain.close();
    await bench.engine.close();
  });

  test("a benchmark result is LiteRT-LM's last prefill and last decode, with "
      'the engine it ran on; a run without both is a StateError', () async {
    final path = write('g4.litertlm', _bundle(family: 8));
    final engine = await create(path, backend: const Backend.gpu());
    final result = llmBenchmarkResultOf(
      (
        initSeconds: 1.5,
        timeToFirstTokenSeconds: 0.25,
        prefill: [
          (tokens: 3, tokensPerSecond: 10.0),
          (tokens: 256, tokensPerSecond: 800.0),
        ],
        decode: [(tokens: 256, tokensPerSecond: 40.0)],
        maxNumTokens: 4096,
      ),
      createTime: const Duration(seconds: 2),
      engine: engine,
    );
    expect(result.initTime, const Duration(milliseconds: 1500));
    expect(result.createTime, const Duration(seconds: 2));
    expect(result.timeToFirstToken, const Duration(milliseconds: 250));
    expect([result.prefillTokenCount, result.decodeTokenCount], [256, 256]);
    expect(
      [result.prefillTokensPerSecond, result.decodeTokensPerSecond],
      [800.0, 40.0],
    );
    expect(result.maxNumTokens, 4096);
    expect(result.backend, const Backend.gpu());
    expect(result.activationDataType, ActivationDataType.float32);
    expect(
      () =>
          llmBenchmarkResultOf(null, createTime: Duration.zero, engine: engine),
      throwsStateError,
    );
    expect(
      () => llmBenchmarkResultOf(
        (
          initSeconds: 0,
          timeToFirstTokenSeconds: 0,
          prefill: [(tokens: 256, tokensPerSecond: 1.0)],
          decode: const [],
          maxNumTokens: 0,
        ),
        createTime: Duration.zero,
        engine: engine,
      ),
      throwsStateError,
    );
    await engine.close();
  });

  test("benchmarkInfoOf sums a conversation's turns and keeps the last "
      "decode's speed; a time native did not report is null", () {
    final info = benchmarkInfoOf((
      initSeconds: 0.5,
      timeToFirstTokenSeconds: 0,
      prefill: [
        (tokens: 10, tokensPerSecond: 100.0),
        (tokens: 20, tokensPerSecond: 200.0),
      ],
      decode: [
        (tokens: 5, tokensPerSecond: 7.0),
        (tokens: 6, tokensPerSecond: 9.0),
      ],
      maxNumTokens: 4096,
    ));
    expect(
      [info.inputTokens, info.outputTokens, info.totalTokens],
      [30, 11, 41],
    );
    expect(info.tokensPerSecond, 9.0);
    expect(info.initTimeMs, 500.0);
    expect(info.timeToFirstTokenMs, isNull);
    final empty = benchmarkInfoOf((
      initSeconds: 0,
      timeToFirstTokenSeconds: 0,
      prefill: const [],
      decode: const [],
      maxNumTokens: 0,
    ));
    expect(empty.tokensPerSecond, isNull);
    expect(empty.totalTokens, 0);
  });

  test('benchmark() closes its engine when the conversation cannot be made '
      'or the send fails, and the failure reaches the caller', () async {
    final path = write('g.litertlm', _bundle());
    for (final failCreate in [true, false]) {
      final client = _BenchClient(failCreate: failCreate);
      host = _Host(client: client);
      debugEngineHost = host;
      await expectLater(
        benchmark(modelPath: path, backend: const Backend.cpu()),
        throwsA(anything),
        reason: failCreate ? 'create' : 'send',
      );
      expect(client.conversations, failCreate ? 0 : 1);
      expect(client.shutdowns, 1, reason: failCreate ? 'create' : 'send');
      expect(host.creates.single.benchmarkTokens, (prefill: 256, decode: 256));
    }
  });

  test('a container the bundle reader refuses still has its declared context '
      'read: one below the #318 floor is raised and sent', () async {
    // A text model that is not a TFLite flatbuffer: the bundle reader refuses
    // it (malformed), LiteRT-LM would still read the LlmMetadata.
    final path = write(
      'r.litertlm',
      litertlmContainer([
        (
          type: sectionTfliteModel,
          modelType: 'tf_lite_prefill_decode',
          bytes: [1, 2, 3, 4, 5, 6, 7, 8],
        ),
        (type: 5, modelType: null, bytes: [0x28, ..._varint(512)]),
      ]),
    );
    expect((await readEngineBundle(path)).info, isNull);
    final engine = await create(path);
    expect(engine.maxNumTokens, 1024);
    expect(host.creates.single.maxTokens, 1024);
    await engine.close();
  });

  test('a file whose declared context cannot be read gets 4096 sent on the '
      'CPU and the GPU, and nothing on the NPU', () async {
    final task = write('m.task', Uint8List.fromList(List.filled(64, 7)));
    final cpu = await create(task);
    final gpu = await create(task, backend: const Backend.gpu());
    expect([cpu.maxNumTokens, gpu.maxNumTokens], [4096, 4096]);
    expect(host.creates.map((c) => c.maxTokens), [4096, 4096]);
    await cpu.close();
    await gpu.close();
  });

  test('Gemma 4 on the GPU above 2,048 tokens runs float32; the CPU and a '
      'set value are left alone', () async {
    final path = write('g4.litertlm', _bundle(family: 8));
    final engines = [
      await create(path, backend: const Backend.gpu(), maxNumTokens: 4096),
      await create(path, backend: const Backend.gpu(), maxNumTokens: 2048),
      await create(path, maxNumTokens: 4096),
      await create(
        path,
        backend: const Backend.gpu(),
        maxNumTokens: 4096,
        activation: ActivationDataType.float16,
      ),
    ];
    expect(host.creates.map((c) => c.activationDataType), [0, null, null, 1]);
    expect(
      host.creates.first.gpuActivationReason,
      GpuActivationReason.gemma4LongContext,
    );
    expect(engines.first.activationDataType, ActivationDataType.float32);
    expect(engines[2].activationDataType, isNull, reason: 'CPU');
    for (final e in engines) {
      await e.close();
    }
  });

  test('on an Android GPU, Gemma 4 above 2,048 tokens keeps the bundle\'s '
      'float16 and says so once, in release builds too; float32 asked for is '
      'honoured', () async {
    host = _Host(abiName: 'android_arm64');
    debugEngineHost = host;
    resetAndroidGemma4Float16Note();
    addTearDown(resetAndroidGemma4Float16Note);
    // runtimeLog is silent in release builds: the note must not go through it.
    final logged = <String>[];
    runtimeLogSink = (message, {verbose = false}) => logged.add(message);
    addTearDown(resetRuntimeLogSink);
    final path = write('g4.litertlm', _bundle(family: 8));
    final printed = <String>[];
    final engines = await runZoned(
      () async => [
        await create(path, backend: const Backend.gpu(), maxNumTokens: 4096),
        await create(path, backend: const Backend.gpu(), maxNumTokens: 8192),
        await create(
          path,
          backend: const Backend.gpu(),
          maxNumTokens: 4096,
          activation: ActivationDataType.float32,
        ),
      ],
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    expect(host.creates.map((c) => c.activationDataType), [null, null, 0]);
    expect(
      host.creates.first.gpuActivationReason,
      GpuActivationReason.gemma4LongContextAndroid,
    );
    expect(host.creates.last.gpuActivationReason, isNull);
    final notes = printed.where((l) => l.contains('#4001')).toList();
    expect(notes, hasLength(1), reason: printed.join('\n'));
    expect(notes.single, contains('WARNING'));
    expect(notes.single, contains('maxTokens 4096'));
    expect(notes.single, contains('ActivationDataType.float32'));
    expect(logged.where((l) => l.contains('#4001')), isEmpty);
    for (final e in engines) {
      await e.close();
    }
  });

  test('a FunctionGemma bundle without a declared type runs float32 on the '
      'GPU; a bundle naming no family is left alone', () async {
    final fg = write('fg.litertlm', _bundle(family: 3));
    final none = write('none.litertlm', _bundle());
    final a = await create(fg, backend: const Backend.gpu());
    final b = await create(
      none,
      backend: const Backend.gpu(),
      maxNumTokens: 8192,
    );
    expect(host.creates.map((c) => c.activationDataType), [0, null]);
    expect(
      host.creates.first.gpuActivationReason,
      GpuActivationReason.functionGemmaWithoutKey,
    );
    await a.close();
    await b.close();
  });

  test('null encoders load none; an encoder where the file wants it is the '
      "file's choice", () async {
    final path = write('enc.litertlm', _bundle(vision: 'gpu'));
    final bundle = await readBundleInfo(path);
    expect(bundle.declaredVisionBackend, const Backend.gpu());
    expect(bundle.declaredAudioBackend, const Backend.cpu());
    final none = await create(path);
    final both = await create(
      path,
      visionBackend: bundle.declaredVisionBackend,
      audioBackend: bundle.declaredAudioBackend,
    );
    expect(host.creates.first.enableVision, isFalse);
    expect(host.creates.first.enableAudio, isFalse);
    expect(
      (
        host.creates.last.enableVision,
        host.creates.last.visionBackend,
        host.creates.last.enableAudio,
        host.creates.last.audioBackend,
      ),
      (true, 'gpu', true, 'cpu'),
      reason: 'vision and audio are not swapped',
    );
    expect(both.visionBackend, const Backend.gpu());
    expect(both.audioBackend, const Backend.cpu());
    await none.close();
    await both.close();
  });

  test('an encoder asked for a backend its file excludes is refused before '
      'any engine', () async {
    final path = write('enc.litertlm', _bundle(vision: 'gpu'));
    await expectLater(
      create(path, visionBackend: const Backend.cpu()),
      throwsA(isA<LiteRtLmBundleException>()),
    );
    expect(host.creates, isEmpty);
  });

  test('speculative decoding: off and on keep the boolean, adaptive goes '
      'through the config; the thread count reaches the CPU only', () async {
    final path = write('g.litertlm', _bundle());
    for (final mode in [
      SpeculativeDecodingMode.off,
      SpeculativeDecodingMode.on,
      SpeculativeDecodingMode.adaptive,
      null,
    ]) {
      await (await create(path, speculative: mode)).close();
    }
    expect(
      host.creates.map(
        (c) => (c.enableSpeculativeDecoding, c.speculativeDecodingMode),
      ),
      [(false, null), (true, null), (null, 2), (null, null)],
    );
    await (await create(
      path,
      backend: const Backend.cpu(threadCount: 3),
    )).close();
    await (await create(path, backend: const Backend.gpu())).close();
    expect(host.creates.skip(4).map((c) => c.numThreads), [3, null]);
  });

  test(
    'the NPU: a prepared directory is used as it is, else the vendor '
    'prepares one; an unreachable NPU is refused before any engine',
    () async {
      final path = write('n.litertlm', _bundle(npu: ('Qualcomm', 'SM8750')));
      host = _Host(abiName: 'android_arm64', npuShips: true);
      debugEngineHost = host;
      final given = await create(
        path,
        backend: Backend.npu(dispatchDir: '/mine'),
      );
      final prepared = await create(path, backend: Backend.npu());
      expect(host.creates.map((c) => c.npuDispatch?.dir), [
        '/mine',
        '/prepared/qualcomm',
      ]);
      expect(engineNpuVendor(prepared), NpuStack.qualcomm);
      await given.close();
      await prepared.close();

      host = _Host(abiName: 'android_arm64');
      debugEngineHost = host;
      await expectLater(
        create(path, backend: Backend.npu()),
        throwsA(isA<NpuDispatchUnavailableException>()),
      );
      expect(host.creates, isEmpty);
    },
  );

  test('a bundle compiled for an NPU is refused on the GPU', () async {
    final path = write('n.litertlm', _bundle(npu: ('Qualcomm', 'SM8750')));
    await expectLater(
      create(path, backend: const Backend.gpu()),
      throwsA(isA<LiteRtLmBundleException>()),
    );
    expect(host.creates, isEmpty);
  });

  test(
    'createEngineWithBundle decides from the bundle it is given, without '
    'reading the file again; one read from another file is refused',
    () async {
      final path = write('n.litertlm', _bundle(npu: ('Qualcomm', 'SM8750')));
      final read = await readEngineBundle(path);
      // The file now holds a generic bundle: a create that read it again would
      // load it on the GPU.
      write('n.litertlm', _bundle());
      final config = EngineConfig(
        modelPath: path,
        backend: const Backend.gpu(),
      );
      await expectLater(
        createEngineWithBundle(config, read),
        throwsA(isA<LiteRtLmBundleException>()),
      );
      expect(host.creates, isEmpty);
      final engine = await Engine.create(config);
      expect(host.creates.single.backend, 'gpu');
      await engine.close();
      expect(
        () => createEngineWithBundle(
          EngineConfig(modelPath: '${dir.path}/other.litertlm'),
          read,
        ),
        throwsArgumentError,
      );
    },
  );

  test('the tool-call reader createEngineWithBundle takes is the one its '
      'conversations replay with; Engine.create reads native calls', () async {
    host = _Host(abiName: 'ios_arm64');
    debugEngineHost = host;
    final path = write('g.litertlm', _bundle());
    List<({String name, Map<String, Object?> arguments})> reader(String raw) =>
        const [];
    final withReader = await createEngineWithBundle(
      EngineConfig(modelPath: path),
      await readEngineBundle(path),
      toolCallsOf: reader,
    );
    final plain = await Engine.create(EngineConfig(modelPath: path));
    final a = await withReader.createConversation();
    final b = await plain.createConversation();
    expect(
      (conversationHandle(a) as VirtualConversationHandle).toolCallsOf,
      same(reader),
    );
    expect(
      (conversationHandle(b) as VirtualConversationHandle).toolCallsOf,
      same(nativeToolCalls),
    );
    await a.close();
    await b.close();
    await withReader.close();
    await plain.close();
  });

  test('a CPU thread count below 1 is refused before any engine', () async {
    final path = write('g.litertlm', _bundle());
    for (final count in [0, -2]) {
      await expectLater(
        create(path, backend: Backend.cpu(threadCount: count)),
        throwsArgumentError,
      );
    }
    expect(host.creates, isEmpty);
    final engine = await create(
      path,
      backend: const Backend.cpu(threadCount: 2),
    );
    expect(host.creates.single.numThreads, 2);
    await engine.close();
  });

  test('creates run one at a time across engines', () async {
    final path = write('g.litertlm', _bundle());
    final engines = await Future.wait([
      for (var i = 0; i < 3; i++) create(path),
    ]);
    expect(host.mostAtOnce, 1);
    for (final e in engines) {
      await e.close();
    }
  });

  test('each create takes the native log level set when it was asked for, '
      'not when its turn came', () async {
    final path = write('g.litertlm', _bundle());
    LiteRtLmLog.nativeLevel = LiteRtLmLogLevel.silent;
    final quiet = create(path);
    LiteRtLmLog.nativeLevel = null;
    final plain = create(path);
    for (final e in await Future.wait([quiet, plain])) {
      await e.close();
    }
    expect(host.nativeLevels, [LiteRtLmLogLevel.silent, null]);
  });

  test('a plain Dart program runs on the CPU only: a GPU or NPU engine or '
      'encoder is refused by name before any engine, never moved', () async {
    host = _Host(outsideFlutter: true);
    debugEngineHost = host;
    final path = write('enc.litertlm', _bundle(vision: 'gpu'));
    for (final (backend, vision, audio, named) in [
      (const Backend.gpu(), null, null, 'The engine on Backend.gpu()'),
      (Backend.npu(), null, null, 'The engine on Backend.npu()'),
      (null, const Backend.gpu(), null, 'The vision encoder on Backend.gpu()'),
      (null, null, Backend.npu(), 'The audio encoder on Backend.npu()'),
    ]) {
      await expectLater(
        create(
          path,
          backend: backend,
          visionBackend: vision,
          audioBackend: audio,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(named),
              contains('not supported outside Flutter'),
              contains('CPU only'),
            ),
          ),
        ),
        reason: named,
      );
    }
    expect(host.creates, isEmpty);
    expect(host.prepared, isEmpty, reason: 'no NPU dispatch prepared');

    final cpu = await create(
      write('g.litertlm', _bundle()),
      visionBackend: const Backend.cpu(),
      audioBackend: const Backend.cpu(),
    );
    expect(host.creates.single.backend, 'cpu');
    await cpu.close();
  });

  test('a plain Dart program refuses a file the CPU cannot run before the '
      'load plan, whose advice (another backend) does not apply', () async {
    host = _Host(outsideFlutter: true);
    debugEngineHost = host;
    final npu = write('n.litertlm', _bundle(npu: ('Qualcomm', 'SM8750')));
    final gpuVision = write('v.litertlm', _bundle(vision: 'gpu'));
    final gpuText = write('t.litertlm', _bundle(text: 'gpu'));
    for (final (path, vision, named) in [
      (npu, null, 'compiled for an NPU'),
      (gpuVision, const Backend.cpu(), 'vision encoder declares'),
      (gpuText, null, 'declares that it runs on gpu'),
    ]) {
      await expectLater(
        create(path, visionBackend: vision),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(named),
              contains('CPU only'),
              isNot(contains('Omit')),
            ),
          ),
        ),
        reason: named,
      );
    }
    expect(host.creates, isEmpty);
    // Names the load plan does not know are not a refusal, as there.
    final unknown = await create(write('u.litertlm', _bundle(text: 'tpu')));
    await unknown.close();
    // A GPU-only vision encoder is not in the way when images are off.
    final engine = await create(gpuVision);
    await engine.close();
  });

  test('the real host is a plain Dart program under dart test', () {
    expect(const EngineHost().outsideFlutter, isTrue);
  });
}
