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
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart'
    show NpuDispatch;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart' show NpuVendor;
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
    NpuStackCheck stack = const NpuStackCheck.bundled(),
    this.npuShips = false,
    this.failures = const {},
  }) : stackCheck = stack;

  final String os;
  final String abiName;
  final NpuStackCheck stackCheck;
  final bool npuShips;

  /// The error each backend's create throws; a backend not here succeeds.
  final Map<String, Exception> failures;

  final attempts = <_Attempt>[];
  int stackChecks = 0;
  int npuProbes = 0;

  /// Every vendor whose stack or device was asked about, in order.
  final askedVendors = <NpuVendor>[];

  /// The vendor whose dispatch directory each NPU attempt prepared.
  final preparedFor = <NpuVendor>[];

  /// The NPU dispatch handed to each attempt, in order (null for gpu/cpu).
  final npuDispatches = <NpuDispatch?>[];

  @override
  Future<String> cacheDir() async => Directory.systemTemp.path;

  @override
  String get operatingSystem => os;

  @override
  String get abi => abiName;

  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) async {
    stackChecks++;
    askedVendors.add(vendor);
    return stackCheck;
  }

  @override
  String? unreachable(NpuVendor vendor) {
    npuProbes++;
    askedVendors.add(vendor);
    return npuShips ? null : 'the fake host has no NPU';
  }

  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) async {
    preparedFor.add(vendor);
    return '/fake/npu/${vendor.name}';
  }

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
    required NpuDispatch? npuDispatch,
  }) async {
    attempts.add((
      backend: backend,
      visionBackend: visionBackend,
      audioBackend: audioBackend,
    ));
    npuDispatches.add(npuDispatch);
    if (failures[backend] case final error?) throw error;
  }
}

/// A Gemma 4-shaped container: the text model, optionally the two encoders
/// and a `tf_lite_aux` section, each with the `backend_constraint` given; the
/// text model and the vision encoder stamped for an NPU when asked.
Uint8List _bundle({
  String? text,
  (String, String)? textStamp,
  String? vision,
  (String, String)? visionStamp,
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
        bytes: tfliteModel({
          if (visionStamp != null)
            'LiteRtStamp': liteRtStamp(visionStamp.$1, visionStamp.$2),
        }),
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

  test(
    'an NPU attempt gets the dispatch of the vendor its bundle is stamped '
    'for, and a generic bundle that of the vendor this host reaches',
    () async {
      host = _FakeHost(os: 'android', abiName: 'android_arm64', npuShips: true);
      debugLiteRtLmEngineHost = host;
      final stamped = await load(
        write('sm8750.litertlm', _bundle(textStamp: ('Qualcomm', 'SM8750'))),
      );
      expect(host.attempts.map((a) => a.backend), ['npu']);
      expect(host.askedVendors, [NpuVendor.qualcomm, NpuVendor.qualcomm]);
      expect(host.preparedFor, [NpuVendor.qualcomm]);
      expect(host.npuDispatches.single, (
        dir: '/fake/npu/qualcomm',
        disableHwMasking: false,
      ));
      await stamped.close();

      host = _FakeHost(os: 'android', abiName: 'android_arm64', npuShips: true);
      debugLiteRtLmEngineHost = host;
      final generic = await load(
        write('generic.litertlm', _bundle()),
        preferredBackend: PreferredBackend.npu,
      );
      expect(host.attempts.map((a) => a.backend), ['npu']);
      expect(host.preparedFor, [NpuVendor.qualcomm]);
      await generic.close();
    },
  );

  test('Windows x64: the Intel stack is checked before the NPU is tried, and '
      'an Intel attempt turns the HW mask update path off', () async {
    host = _FakeHost(os: 'windows', abiName: 'windows_x64', npuShips: true);
    debugLiteRtLmEngineHost = host;
    final path = write('generic.litertlm', _bundle());
    final model = await load(path, preferredBackend: PreferredBackend.npu);
    expect(host.attempts.map((a) => a.backend), ['npu']);
    expect(host.askedVendors, [NpuVendor.intel, NpuVendor.intel]);
    expect(host.npuDispatches.single, (
      dir: '/fake/npu/intel',
      disableHwMasking: true,
    ));
    await model.close();

    const missing = r'LiteRtDispatch.dll is not beside the executable (C:\app)';
    host = _FakeHost(
      os: 'windows',
      abiName: 'windows_x64',
      npuShips: true,
      stack: const NpuStackCheck.missing(missing),
    );
    debugLiteRtLmEngineHost = host;
    late InferenceModel fallback;
    final printed = await printedBy(() async {
      fallback = await load(path, preferredBackend: PreferredBackend.npu);
    });
    expect(host.attempts.map((a) => a.backend), ['gpu']);
    expect(host.npuProbes, 0, reason: 'the build is asked before the device');
    expect(host.preparedFor, isEmpty);
    expect(
      printed.single,
      contains('npu was requested, but $missing — trying gpu -> cpu'),
    );
    await fallback.close();
  });

  test('an app without the opt-in stack is told so, word for word, and the '
      'device is not probed', () async {
    const notEnabled = 'this app was built without the Qualcomm NPU stack';
    host = _FakeHost(
      os: 'android',
      abiName: 'android_arm64',
      npuShips: true,
      stack: const NpuStackCheck.missing(notEnabled),
    );
    debugLiteRtLmEngineHost = host;
    late InferenceModel model;
    final printed = await printedBy(() async {
      model = await load(
        write('generic.litertlm', _bundle()),
        preferredBackend: PreferredBackend.npu,
      );
    });
    expect(host.attempts.map((a) => a.backend), ['gpu']);
    expect(host.npuProbes, 0);
    expect(
      printed.single,
      contains('npu was requested, but $notEnabled — trying gpu -> cpu'),
    );
    await model.close();
  });

  test('a host no vendor runs on drops the NPU naming its ABI, with nothing '
      'asked', () async {
    for (final (os, abi) in [
      ('macos', 'macos_arm64'),
      ('linux', 'linux_x64'),
      ('android', 'android_x64'),
      ('windows', 'windows_arm64'),
    ]) {
      host = _FakeHost(os: os, abiName: abi, npuShips: true);
      debugLiteRtLmEngineHost = host;
      late InferenceModel model;
      final printed = await printedBy(() async {
        model = await load(
          write('generic_$abi.litertlm', _bundle()),
          preferredBackend: PreferredBackend.npu,
        );
      });
      expect(host.attempts.map((a) => a.backend), ['gpu'], reason: abi);
      expect(host.npuDispatches, [null], reason: abi);
      expect(host.askedVendors, isEmpty, reason: abi);
      expect(
        printed.single,
        contains('npu was requested, but no NPU dispatch stack ships for $abi'),
        reason: abi,
      );
      await model.close();
    }
  });

  test(
    'an encoder compiled for an NPU this host has no dispatch for is '
    'refused for what it is, not for the host, and nothing is probed',
    () async {
      host = _FakeHost(os: 'android', abiName: 'android_arm64', npuShips: true);
      debugLiteRtLmEngineHost = host;
      final path = write(
        'vision_mt6991.litertlm',
        _bundle(visionStamp: ('MediaTek', 'MT6991')),
      );

      for (final backendFallback in [false, true]) {
        await expectLater(
          load(
            path,
            preferredBackend: PreferredBackend.npu,
            supportImage: true,
            backendFallback: backendFallback,
          ),
          throwsA(
            isA<LiteRtLmBundleException>()
                .having(
                  (e) => e.problem,
                  'problem',
                  LiteRtLmBundleProblem.unsupportedNpu,
                )
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains(
                      "vision encoder is compiled for the MediaTek "
                      'MT6991 NPU',
                    ),
                    contains('load it without supportImage'),
                  ),
                ),
          ),
          reason: 'backendFallback: $backendFallback',
        );
      }
      expect(host.stackChecks, 0, reason: 'no stack of a foreign vendor');
      expect(host.npuProbes, 0, reason: 'no probe answers for another vendor');
      expect(host.attempts, isEmpty);
    },
  );

  test("the plan's encoder backends reach the client and the model", () async {
    // An encoder on the NPU runs only with a text model on the NPU.
    host = _FakeHost(os: 'android', abiName: 'android_arm64', npuShips: true);
    debugLiteRtLmEngineHost = host;
    final model = await load(
      write('enc.litertlm', _bundle(text: 'npu', vision: 'gpu', audio: 'npu')),
      supportImage: true,
      supportAudio: true,
    );

    expect(host.attempts.single.backend, 'npu');
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

  test('an encoder compiled for an NPU the host has no dispatch for is '
      'checked only when it is on', () async {
    final path = write(
      'vision_npu.litertlm',
      _bundle(visionStamp: ('Qualcomm', 'SM8750')),
    );
    final textOnly = await load(path);
    expect(host.attempts.map((a) => a.backend), ['gpu']);
    expect(textOnly.activeVisionBackend, isNull);
    await textOnly.close();

    host.attempts.clear();
    await expectLater(
      load(path, supportImage: true),
      throwsA(
        isA<LiteRtLmBundleException>()
            .having(
              (e) => e.problem,
              'problem',
              LiteRtLmBundleProblem.unsupportedNpu,
            )
            .having(
              (e) => e.message,
              'message',
              contains(
                "vision encoder is compiled for the Qualcomm SM8750 NPU, which "
                'runs on android_arm64 and linux_arm64 only, and this is '
                'macos_arm64',
              ),
            ),
      ),
    );
    expect(host.attempts, isEmpty, reason: 'refused before any engine');
  });

  test('an encoder compiled for the NPU next to a generic text model asks for '
      "the app's NPU stack, and is refused before any engine", () async {
    host = _FakeHost(
      os: 'android',
      abiName: 'android_arm64',
      stack: const NpuStackCheck.missing(
        'this build does not bundle the Qualcomm NPU stack',
      ),
    );
    debugLiteRtLmEngineHost = host;
    final path = write(
      'vision_sm8750.litertlm',
      _bundle(visionStamp: ('Qualcomm', 'SM8750')),
    );

    await expectLater(
      load(path, supportImage: true),
      throwsA(
        isA<BackendInitException>().having(
          (e) => e.lastAttempt.error,
          'error',
          isA<NpuDispatchUnavailableException>().having(
            (e) => e.message,
            'message',
            "$path's vision encoder is compiled for the Qualcomm SM8750 NPU "
                'and runs only there, and this build does not bundle the '
                'Qualcomm NPU stack',
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
    expect(host.attempts, isEmpty, reason: 'refused before any engine');

    // A text-only load of the same file needs no NPU: GPU, no stack lookup.
    host.stackChecks = 0;
    final textOnly = await load(path);
    expect(host.attempts.map((a) => a.backend), ['gpu']);
    expect(textOnly.activeBackend, PreferredBackend.gpu);
    expect(textOnly.activeVisionBackend, isNull);
    expect(host.stackChecks, 0);
    await textOnly.close();

    // With the stack and an NPU this device reaches, the encoder is still
    // refused: the text model would run on the GPU, which gets no NPU
    // dispatch.
    host = _FakeHost(os: 'android', abiName: 'android_arm64', npuShips: true);
    debugLiteRtLmEngineHost = host;
    await expectLater(
      load(path, supportImage: true),
      throwsA(
        isA<LiteRtLmBundleException>()
            .having(
              (e) => e.problem,
              'problem',
              LiteRtLmBundleProblem.unsupportedNpu,
            )
            .having(
              (e) => e.message,
              'message',
              contains(
                "$path's vision encoder is compiled for the Qualcomm SM8750 "
                'NPU and runs only there, and its text model would be tried '
                'on gpu, then cpu, not on the NPU alone.',
              ),
            ),
      ),
    );
    expect(host.attempts, isEmpty, reason: 'refused before any engine');
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
