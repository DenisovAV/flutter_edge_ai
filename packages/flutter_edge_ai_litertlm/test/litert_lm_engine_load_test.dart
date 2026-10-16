// LiteRtLmEngine.createModel on the VM: a synthetic .litertlm on disk, the
// real bundle reader and load plan, and a fake LiteRtLmEngineHost in place of
// path_provider, the NPU probes and the FFI client. It guards the wiring
// between them, which only a device run reached before: the plan's backends
// and encoders reaching the client and the model, the bundle read's error
// mapping, the app's NPU stack asked before any NPU probe, and the message of
// a failed NPU create.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show LiteRtLmFfiClient;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'litertlm_container_fixture.dart';

typedef _Attempt = ({
  String backend,
  String visionBackend,
  String audioBackend,
});

class _FakeHost extends LiteRtLmEngineHost {
  _FakeHost({
    this.os = 'macos',
    this.abiName = 'macos_arm64',
    this.stack = const NpuStackCheck.bundled(),
    this.npuShips = false,
    this.failures = const {},
  });

  final String os;
  final String abiName;
  final NpuStackCheck stack;
  final bool npuShips;

  /// The error each backend's create throws; a backend not here succeeds.
  final Map<String, Exception> failures;

  final attempts = <_Attempt>[];
  int stackChecks = 0;
  int npuProbes = 0;

  @override
  Future<String> cacheDir() async => Directory.systemTemp.path;

  @override
  String get operatingSystem => os;

  @override
  String get abi => abiName;

  @override
  Future<NpuStackCheck> qualcommNpuStack() async {
    stackChecks++;
    return stack;
  }

  @override
  bool get npuDispatchShips {
    npuProbes++;
    return npuShips;
  }

  @override
  String get npuUnavailableReason => 'the fake host has no NPU';

  @override
  Future<void> initializeClient(
    LiteRtLmFfiClient client, {
    required String modelPath,
    required String backend,
    required int maxTokens,
    required String cacheDir,
    required bool enableVision,
    required String visionBackend,
    required int maxNumImages,
    required bool enableAudio,
    required String audioBackend,
    required bool? enableSpeculativeDecoding,
    required int? activationDataType,
  }) async {
    attempts.add((
      backend: backend,
      visionBackend: visionBackend,
      audioBackend: audioBackend,
    ));
    if (failures[backend] case final error?) throw error;
  }
}

/// A Gemma 4-shaped container: the text model, optionally the two encoders
/// and a `tf_lite_aux` section, each with the `backend_constraint` given.
Uint8List _bundle({
  String? text,
  (String, String)? textStamp,
  String? vision,
  String? audio,
  bool encoders = true,
  bool aux = false,
}) => litertlmContainer(
  [
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_prefill_decode',
      bytes: tfliteModel({
        if (textStamp != null)
          'LiteRtStamp': liteRtStamp(textStamp.$1, textStamp.$2),
      }),
    ),
    if (encoders) ...[
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
    ],
    if (aux)
      (
        type: sectionTfliteModel,
        modelType: 'tf_lite_aux',
        bytes: tfliteModel({}),
      ),
  ],
  items: {
    0: {'backend_constraint': ?text},
    if (encoders) ...{
      1: {'backend_constraint': ?vision},
      2: {'backend_constraint': ?audio},
    },
  },
);

void main() {
  late Directory root;
  late _FakeHost host;

  setUp(() {
    root = Directory.systemTemp.createTempSync('engine_load_');
    host = _FakeHost();
    debugLiteRtLmEngineHost = host;
  });

  tearDown(() {
    debugLiteRtLmEngineHost = null;
    root.deleteSync(recursive: true);
  });

  String write(String name, List<int> bytes) =>
      (File('${root.path}/$name')..writeAsBytesSync(bytes)).path;

  Future<InferenceModel> load(
    String path, {
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
    bool backendFallback = true,
  }) => LiteRtLmEngine(backendFallback: backendFallback).createModel(
    InferenceModelSpec(
      name: 'test',
      modelSource: FileSource(path),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ),
    RuntimeConfig(
      maxTokens: 1024,
      modelPath: path,
      preferredBackend: preferredBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
    ),
  );

  Future<List<String>> printedBy(Future<void> Function() body) async {
    final printed = <String>[];
    await runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    return printed;
  }

  test(
    "the plan's text backends are the ones the client is asked for",
    () async {
      final model = await load(write('cpu.litertlm', _bundle(text: 'cpu')));

      expect(host.attempts.map((a) => a.backend), ['cpu']);
      expect(model.activeBackend, PreferredBackend.cpu);
      await model.close();
    },
  );

  test("the plan's encoder backends reach the client and the model", () async {
    final model = await load(
      write('enc.litertlm', _bundle(vision: 'gpu', audio: 'npu')),
      supportImage: true,
      supportAudio: true,
    );

    expect(host.attempts.single.visionBackend, 'gpu');
    expect(host.attempts.single.audioBackend, 'npu');
    expect(model.activeVisionBackend, PreferredBackend.gpu);
    expect(model.activeAudioBackend, PreferredBackend.npu);
    await model.close();

    final textOnly = await load(
      write('text.litertlm', _bundle(encoders: false)),
      supportImage: true,
    );
    expect(
      textOnly.activeVisionBackend,
      isNull,
      reason: 'the bundle has no vision encoder to run anywhere',
    );
    await textOnly.close();
  });

  test('a file that ends inside its header is refused before any '
      'engine', () async {
    final whole = _bundle();
    await expectLater(
      load(write('cut.litertlm', whole.sublist(0, 40))),
      throwsA(
        isA<LiteRtLmBundleException>().having(
          (e) => e.problem,
          'problem',
          LiteRtLmBundleProblem.incomplete,
        ),
      ),
    );
    expect(host.attempts, isEmpty);
  });

  test('a file the reader cannot read loads by the rules that need no '
      'file', () async {
    final newer = _bundle(encoders: false);
    ByteData.sublistView(newer).setUint32(8, 2, Endian.little);
    final malformed = _bundle(encoders: false);
    // A header end past 4 GiB.
    ByteData.sublistView(malformed).setUint32(28, 1, Endian.little);
    final files = {
      'notLitertlm': write('m.task', [0x50, 0x4b, 3, 4, ...List.filled(60, 0)]),
      'unsupportedVersion': write('v2.litertlm', newer),
      'malformed': write('bad.litertlm', malformed),
      'missing': '${root.path}/absent.litertlm',
    };
    for (final MapEntry(key: name, value: path) in files.entries) {
      host.attempts.clear();
      final model = await load(path, supportImage: true);
      expect(host.attempts.map((a) => a.backend), ['gpu'], reason: name);
      expect(
        model.activeVisionBackend,
        PreferredBackend.cpu,
        reason: '$name: an unread file keeps the CPU for its vision encoder',
      );
      await model.close();
    }
  });

  test('a text model that declares only the NPU asks for the app\'s NPU '
      'stack before any NPU probe', () async {
    host = _FakeHost(
      os: 'android',
      abiName: 'android_arm64',
      stack: const NpuStackCheck.missing(
        'this build does not bundle the Qualcomm NPU stack',
      ),
    );
    debugLiteRtLmEngineHost = host;

    await expectLater(
      load(write('npu.litertlm', _bundle(text: 'npu'))),
      throwsA(
        isA<BackendInitException>().having(
          (e) => e.lastAttempt.error,
          'error',
          isA<NpuDispatchUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('does not bundle the Qualcomm NPU stack'),
          ),
        ),
      ),
    );
    expect(host.stackChecks, 1);
    expect(
      host.npuProbes,
      0,
      reason: 'without the opt-in no vendor library may be opened',
    );
    expect(host.attempts, isEmpty);
  });

  test('a requested NPU the file rules out is printed with the declared '
      'constraint', () async {
    final path = write('3n.litertlm', _bundle(text: 'cpu,gpu'));
    late InferenceModel model;
    final printed = await printedBy(() async {
      model = await load(path, preferredBackend: PreferredBackend.npu);
    });

    expect(host.attempts.map((a) => a.backend), ['gpu']);
    expect(
      printed.where((l) => l.contains('npu was requested')).single,
      contains(
        'npu was requested, but $path declares that its text model runs on '
        'cpu, gpu (backend_constraint) — trying gpu -> cpu instead',
      ),
    );
    await model.close();
  });

  test('a failed NPU create names the SoC the bundle is compiled for, as a '
      'possible cause', () async {
    host = _FakeHost(
      os: 'android',
      abiName: 'android_arm64',
      npuShips: true,
      failures: {
        'npu': const LiteRtLmEngineCreateException(
          'Failed to create engine on npu: INTERNAL: no dispatch. Model: m',
          nativeCode: 13,
          nativeMessage: 'INTERNAL: no dispatch',
        ),
        'gpu': const LiteRtLmEngineCreateException('gpu create failed'),
      },
    );
    debugLiteRtLmEngineHost = host;

    await expectLater(
      load(
        write(
          'sm8750.litertlm',
          _bundle(textStamp: ('Qualcomm', 'SM8750'), aux: true),
        ),
      ),
      throwsA(
        isA<BackendInitException>()
            .having((e) => e.attempts.length, 'attempts', 1)
            .having(
              (e) => e.lastAttempt.error,
              'error',
              isA<LiteRtLmEngineCreateException>()
                  .having(
                    (e) => e.message,
                    'message',
                    'Failed to create engine on npu: INTERNAL: no dispatch. '
                        'Model: m. The bundle is compiled for the Qualcomm '
                        'SM8750 NPU; if this device is not a Qualcomm SM8750, '
                        'that is the cause.',
                  )
                  .having((e) => e.nativeCode, 'nativeCode', 13)
                  .having(
                    (e) => e.nativeMessage,
                    'nativeMessage',
                    'INTERNAL: no dispatch',
                  ),
            ),
      ),
    );
    expect(host.attempts.map((a) => a.backend), ['npu']);

    // A create that fails on another backend keeps its own message.
    host.attempts.clear();
    await expectLater(
      load(
        write('generic.litertlm', _bundle(text: 'gpu')),
        backendFallback: false,
      ),
      throwsA(
        isA<BackendInitException>().having(
          (e) => (e.lastAttempt.error as LiteRtLmEngineCreateException).message,
          'message',
          'gpu create failed',
        ),
      ),
    );
  });
}
