// Engine.create on the VM: a synthetic .litertlm on disk, the real bundle
// reader and load plan, and a fake EngineHost in place of the NPU probes and
// the native engine create. It holds what the runtime decides before LiteRT-LM
// is called: the context floor, the GPU activation rules, the encoders, the
// speculative decoding mode, the thread count, the NPU dispatch, and one
// create at a time.
import 'dart:async';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

typedef _Create = ({
  String backend,
  int maxTokens,
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

class _Host extends EngineHost implements LiteRtLmNpuHost {
  _Host({this.abiName = 'macos_arm64', this.npuShips = false});

  final String abiName;
  final bool npuShips;
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
    required int maxTokens,
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
  }) async {
    if (initializeError case final e?) throw e;
    nativeLevels.add(nativeLogLevel);
    mostAtOnce = max(mostAtOnce, ++creating);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    creating--;
    creates.add((
      backend: backend,
      maxTokens: maxTokens,
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
    if (family != null)
      (type: 5, modelType: null, bytes: [0x32, 2, (family << 3) | 2, 0]),
  ],
  items: {
    0: {'backend_constraint': ?text},
    1: {'backend_constraint': ?vision},
  },
);

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

  test('a libLiteRtLm that does not load, or is not a build this release '
      'drives, is a LiteRtLmLibraryException; a bad argument stays an '
      'ArgumentError', () async {
    final generic = write('g.litertlm', _bundle());
    for (final error in <Object>[
      Exception('Failed to load libLiteRtLm.so with RTLD_GLOBAL'),
      StateError('libLiteRtLm is not C API 1.x'),
      UnsupportedError('LiteRT-LM did not load on macOS'),
    ]) {
      host.initializeError = error;
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
    host.initializeError = null;
    await expectLater(
      create(generic, backend: const Backend.cpu(threadCount: 0)),
      throwsArgumentError,
    );
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
}
