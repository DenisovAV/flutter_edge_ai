// `placeLiteRtLmEmbedder`: where an EmbeddingGemma 2 bundle runs, and every
// refusal (owner-approved design, 2026-10-12) — nothing switches backend on
// its own, because NPU and CPU vectors are not interchangeable. The host is a
// fake: every answer it gives is a property of a device a test host is not.

import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_common.dart'
    show liteRtLmWebNpuRefusal;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_npu.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show NpuDispatchUnavailableException;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = 'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm';
const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');
const _tensorG5 = LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5');
const _tensorG6 = LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6');

/// What Google's `…_Intel_PTL.litertlm` bundles are stamped with.
const _ptl = LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL');

Matcher _refusal(Object message) => throwsA(
  isA<EmbeddingLoadException>()
      .having((e) => e.engine, 'engine', 'LiteRT-LM')
      .having((e) => e.message, 'message', message),
);

void main() {
  late _FakeHost host;

  setUp(() => host = _FakeHost());

  Future<LiteRtLmEmbeddingPlacement> place({
    LiteRtLmNpuTarget? target = _sm8850,
    PreferredBackend? requested = PreferredBackend.npu,
  }) => placeLiteRtLmEmbedder(
    file: _file,
    target: target,
    requested: requested,
    host: host,
  );

  group('the generic bundle', () {
    test(
      'runs on CPU for every request but npu, asking the host nothing',
      () async {
        for (final requested in [
          null,
          PreferredBackend.cpu,
          PreferredBackend.gpu,
        ]) {
          final placement = await place(target: null, requested: requested);
          expect(placement.backend, PreferredBackend.cpu, reason: '$requested');
          expect(placement.target, isNull);
          expect(placement.dispatchDir, isNull);
        }
        expect(host.asked, isEmpty);
      },
    );

    test(
      'with npu is refused, naming the per-SoC bundles — never run on CPU',
      () async {
        await expectLater(
          place(target: null),
          _refusal(
            allOf(
              contains('generic EmbeddingGemma 2 bundle'),
              contains('no NPU graph'),
              contains('_Qualcomm_<SoC>.litertlm'),
              contains('_Google_Tensor_G5'),
              contains('<model>_Intel_PTL.litertlm'),
              contains('SM8850, SM8650, QCS8275 are device-verified'),
              contains('omit preferredBackend'),
            ),
          ),
        );
        expect(host.asked, isEmpty);
      },
    );
  });

  group('a per-SoC bundle', () {
    test('without npu is refused: it runs on its NPU or not at all', () async {
      for (final requested in [
        null,
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]) {
        await expectLater(
          place(requested: requested),
          _refusal(
            allOf(
              contains('compiled for the Qualcomm SM8850 NPU'),
              contains('preferredBackend: PreferredBackend.npu'),
              contains('generic EmbeddingGemma 2 bundle'),
              contains('its own profile id'),
            ),
          ),
          reason: '$requested',
        );
      }
      expect(host.asked, isEmpty);
    });

    test('with npu on Qualcomm Android arm64 runs on the NPU, with the '
        "host's dispatch directory", () async {
      final placement = await place();
      expect(placement.backend, PreferredBackend.npu);
      expect(placement.target, _sm8850);
      expect(placement.dispatchDir, '/data/app/code_cache/npu');
      expect(host.asked, ['stack', 'hasNpu', 'dispatchDir']);
    });

    test('with npu on Qualcomm Linux arm64 too', () async {
      host
        ..operatingSystem = 'linux'
        ..abi = 'linux_arm64';
      expect((await place()).backend, PreferredBackend.npu);
    });

    for (final (os, abi) in [
      ('ios', 'ios_arm64'),
      ('macos', 'macos_arm64'),
      ('windows', 'windows_arm64'),
      ('linux', 'linux_x64'),
      ('android', 'android_x64'),
    ]) {
      test('with npu on $abi is refused before anything is asked', () async {
        host
          ..operatingSystem = os
          ..abi = abi;
        for (final target in const [_sm8850, _ptl]) {
          await expectLater(
            place(target: target),
            _refusal(
              allOf(
                contains(
                  'Google Tensor or Qualcomm Android, Qualcomm Linux arm64, '
                  'and Intel Windows x64 only',
                ),
                contains('this is $os ($abi)'),
                contains('generic EmbeddingGemma 2 bundle'),
              ),
            ),
            reason: '$target',
          );
        }
        expect(host.asked, isEmpty);
      });
    }

    test('compiled for another vendor is refused, on Android and on Windows '
        'alike', () async {
      for (final (os, abi) in [
        ('android', 'android_arm64'),
        ('windows', 'windows_x64'),
      ]) {
        host
          ..operatingSystem = os
          ..abi = abi;
        for (final target in const [
          LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991'),
          // Only LiteRT's OpenVINO stamp is an Intel bundle this runs.
          LiteRtLmNpuTarget(vendor: 'Intel', soc: 'PTL'),
        ]) {
          await expectLater(
            place(target: target),
            _refusal(
              allOf(
                contains('compiled for a ${target.vendor} NPU (${target.soc})'),
                contains('Google Tensor, Qualcomm, and Intel NPUs only'),
              ),
            ),
            reason: '$abi $target',
          );
        }
      }
      expect(host.asked, isEmpty);
    });

    test('compiled for Qualcomm is refused on Windows x64, which runs Intel '
        'bundles', () async {
      host
        ..operatingSystem = 'windows'
        ..abi = 'windows_x64';
      await expectLater(
        place(),
        _refusal(
          allOf(
            contains('compiled for the Qualcomm SM8850 NPU'),
            contains(
              'on windows (windows_x64) flutter_edge_ai_litertlm runs Intel '
              'NPU bundles only; Qualcomm ones run on android_arm64 and '
              'linux_arm64',
            ),
            contains('generic EmbeddingGemma 2 bundle'),
          ),
        ),
      );
      expect(host.asked, isEmpty);
    });

    test('in an app built without the opt-in stack is refused with how to '
        'opt in', () async {
      host.stack = const NpuStackCheck.missing(qualcommNpuNotEnabledReason);
      await expectLater(
        place(),
        _refusal(
          allOf(
            contains('needs the Qualcomm SM8850 NPU'),
            contains('qualcomm_npu: true'),
          ),
        ),
      );
      expect(host.asked, ['stack']);
    });

    test('an unanswerable manifest is not a no: the device is asked', () async {
      host.stack = const NpuStackCheck.unknown('no binding');
      expect((await place()).backend, PreferredBackend.npu);
      expect(host.asked, ['stack', 'hasNpu', 'dispatchDir']);
    });

    test(
      'on a device without the NPU is refused with the probe\'s reason',
      () async {
        host
          ..npuPresent = false
          ..unavailableReason = 'this device has no Qualcomm FastRPC';
        await expectLater(
          place(),
          _refusal(
            'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm needs the '
            'Qualcomm SM8850 NPU, and this device has no Qualcomm FastRPC.',
          ),
        );
        expect(host.asked, ['stack', 'hasNpu']);
      },
    );

    test(
      'whose libraries cannot be prepared is refused, the cause kept',
      () async {
        host.dispatchError = const NpuDispatchUnavailableException(
          'libQnnHtpV81Skel.so is missing',
        );
        await expectLater(
          place(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('could not be prepared'),
                    contains('libQnnHtpV81Skel.so is missing'),
                  ),
                )
                .having(
                  (e) => e.cause,
                  'cause',
                  isA<NpuDispatchUnavailableException>(),
                ),
          ),
        );
      },
    );
  });

  group('Google Tensor bundles', () {
    for (final target in const [_tensorG5, _tensorG6]) {
      test(
        '${target.soc} runs on Android arm64 with the Google stack',
        () async {
          final placement = await place(target: target);
          expect(placement.backend, PreferredBackend.npu);
          expect(placement.target, target);
          expect(placement.dispatchDir, '/data/app/code_cache/npu');
          expect(host.asked, ['googleStack', 'hasNpu', 'dispatchDir']);
        },
      );
    }

    test('a missing Pixel system runtime is a clear refusal', () async {
      host
        ..npuPresent = false
        ..unavailableReason =
            'the Google Tensor system runtime libedgetpu_litert.so did not open';
      await expectLater(
        place(target: _tensorG5),
        _refusal(
          allOf(
            contains('needs the Google Tensor_G5 NPU'),
            contains('libedgetpu_litert.so did not open'),
          ),
        ),
      );
      expect(host.asked, ['googleStack', 'hasNpu']);
    });

    test(
      'is refused on unsupported platforms before any runtime probe',
      () async {
        host
          ..operatingSystem = 'linux'
          ..abi = 'linux_arm64';
        await expectLater(
          place(target: _tensorG6),
          _refusal(contains('Google ones run on android_arm64')),
        );
        expect(host.asked, isEmpty);
      },
    );
  });

  group('an Intel (Panther Lake) bundle', () {
    setUp(
      () => host
        ..operatingSystem = 'windows'
        ..abi = 'windows_x64'
        ..dispatchDir = r'C:\Apps\demo',
    );

    test('with npu on Windows x64 runs on the NPU, with the dispatch next to '
        'the executable — no Qualcomm stack and no FastRPC asked', () async {
      final placement = await place(target: _ptl);
      expect(placement.backend, PreferredBackend.npu);
      expect(placement.target, _ptl);
      expect(placement.target!.isIntel, isTrue);
      expect(placement.dispatchDir, r'C:\Apps\demo');
      expect(host.asked, ['intelStack', 'dispatchDir']);
    });

    test('without npu is refused like any per-SoC bundle', () async {
      await expectLater(
        place(target: _ptl, requested: null),
        _refusal(
          allOf(
            contains('compiled for the IntelOpenVINO PTL NPU'),
            contains('on a PTL device'),
          ),
        ),
      );
      expect(host.asked, isEmpty);
    });

    test('on Qualcomm Android and Linux arm64 is refused before anything is '
        'asked', () async {
      for (final (os, abi) in [
        ('android', 'android_arm64'),
        ('linux', 'linux_arm64'),
      ]) {
        host
          ..operatingSystem = os
          ..abi = abi;
        await expectLater(
          place(target: _ptl),
          _refusal(
            allOf(
              contains('compiled for the IntelOpenVINO PTL NPU'),
              contains(
                'on $os ($abi) flutter_edge_ai_litertlm runs '
                '${os == 'android' ? 'Google and Qualcomm' : 'Qualcomm'} NPU '
                'bundles only; Intel ones run on windows_x64',
              ),
            ),
          ),
          reason: abi,
        );
      }
      expect(host.asked, isEmpty);
    });

    test('where the Intel stack is missing is refused with why', () async {
      host.intel = const NpuStackCheck.missing(
        r'LiteRtDispatch.dll is not beside the executable (C:\Apps\demo)',
      );
      await expectLater(
        place(target: _ptl),
        _refusal(
          r'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm needs the '
          r'IntelOpenVINO PTL NPU, and LiteRtDispatch.dll is not beside the '
          r'executable (C:\Apps\demo).',
        ),
      );
      expect(host.asked, ['intelStack']);
    });

    test('whose dispatch directory cannot be resolved is refused, the cause '
        'kept', () async {
      host.dispatchError = const NpuDispatchUnavailableException('no exe');
      await expectLater(
        place(target: _ptl),
        _refusal(contains('its Intel libraries could not be prepared: no exe')),
      );
    });
  });

  test('the web refusal names both NPU hosts, Intel included', () {
    expect(
      liteRtLmWebNpuRefusal,
      allOf(
        contains('Qualcomm Android and Qualcomm Linux arm64'),
        contains('Intel NPUs with Windows x64'),
        contains('not on the web'),
      ),
    );
  });

  group('the Intel stack check', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('intel_npu_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('finds LiteRtDispatch.dll in the directory it is given', () {
      File(
        '${dir.path}${Platform.pathSeparator}LiteRtDispatch.dll',
      ).writeAsBytesSync(const [0]);
      final check = checkIntelNpuStack(dir.path);
      expect(check.bundled, isTrue);
      expect(check.known, isTrue);
    });

    test('says where it looked when the dispatch is not there — other Intel '
        'libraries do not count', () {
      File(
        '${dir.path}${Platform.pathSeparator}openvino.dll',
      ).writeAsBytesSync(const [0]);
      final check = checkIntelNpuStack(dir.path);
      expect(check.bundled, isFalse);
      expect(check.known, isTrue, reason: 'a missing file is an answer');
      expect(
        check.reason,
        allOf(
          contains('LiteRtDispatch.dll is not beside the executable'),
          contains(dir.path),
          contains('ship all the DLLs'),
        ),
      );
    });

    test('the platform host looks beside the running executable', () async {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      expect(windowsNpuDispatchDir, exeDir);
      // No test runner ships LiteRtDispatch.dll beside itself.
      final check = await const LiteRtLmPlatformNpuHost().intelStack();
      expect(check.bundled, isFalse);
      expect(check.reason, contains('($exeDir)'));
    });

    test('Windows hands LiteRT the executable\'s directory', () async {
      expect(await npuDispatchDirFor('windows'), windowsNpuDispatchDir);
    });
  });
}

final class _FakeHost implements LiteRtLmNpuHost {
  @override
  String operatingSystem = 'android';

  @override
  String abi = 'android_arm64';

  NpuStackCheck stack = const NpuStackCheck.bundled();

  NpuStackCheck intel = const NpuStackCheck.bundled();

  NpuStackCheck google = const NpuStackCheck.bundled();

  String dispatchDir = '/data/app/code_cache/npu';

  bool _hasNpu = true;

  String unavailableReason = 'no NPU';

  NpuDispatchUnavailableException? dispatchError;

  final asked = <String>[];

  set npuPresent(bool value) => _hasNpu = value;

  @override
  bool hasNpu(LiteRtLmNpuTarget target) {
    asked.add('hasNpu');
    return _hasNpu;
  }

  @override
  String noNpuReason(LiteRtLmNpuTarget target) => unavailableReason;

  @override
  Future<NpuStackCheck> qualcommStack() async {
    asked.add('stack');
    return stack;
  }

  @override
  Future<NpuStackCheck> googleTensorStack() async {
    asked.add('googleStack');
    return google;
  }

  @override
  Future<NpuStackCheck> intelStack() async {
    asked.add('intelStack');
    return intel;
  }

  @override
  Future<String> prepareDispatchDir(LiteRtLmNpuTarget target) async {
    asked.add('dispatchDir');
    final error = dispatchError;
    if (error != null) throw error;
    return dispatchDir;
  }
}
