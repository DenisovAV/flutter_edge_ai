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
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = 'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm';
const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');

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
        // The fake host is android_arm64, where the GPU is not measured.
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

    test('the GPU hosts are exactly the measured ones: Windows x64 and '
        'Linux x64', () {
      expect(liteRtLmEmbeddingGpuAbis, {'windows_x64', 'linux_x64'});
    });

    for (final abi in liteRtLmEmbeddingGpuAbis) {
      test(
        'with gpu on $abi runs on the GPU; null and cpu stay on CPU',
        () async {
          host
            ..abi = abi
            ..operatingSystem = abi.split('_').first;
          expect(
            (await place(
              target: null,
              requested: PreferredBackend.gpu,
            )).backend,
            PreferredBackend.gpu,
          );
          for (final requested in [null, PreferredBackend.cpu]) {
            expect(
              (await place(target: null, requested: requested)).backend,
              PreferredBackend.cpu,
              reason: '$requested',
            );
          }
          expect(host.asked, isEmpty);
        },
      );
    }

    for (final abi in [
      'macos_arm64',
      'ios_arm64',
      'android_arm64',
      'linux_arm64',
      'windows_arm64',
    ]) {
      test('with gpu on $abi stays on CPU: the GPU is not measured there '
          '(Metal ends the process at create on Apple)', () async {
        host.abi = abi;
        final placement = await place(
          target: null,
          requested: PreferredBackend.gpu,
        );
        expect(placement.backend, PreferredBackend.cpu);
      });
    }

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
              contains('<model>_Google_Tensor_G5|G6.litertlm'),
              contains('<model>_Intel_PTL.litertlm'),
              contains('https://flutteredge.ai/docs/registry'),
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
      expect(host.asked, ['stack:qualcomm', 'reaches', 'dispatchDir']);
      expect(host.vendors, {NpuStack.qualcomm}, reason: 'one vendor asked');
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
                  'Qualcomm Android and Qualcomm Linux arm64, and on Google '
                  'Tensor G5/G6 Android devices, and on MediaTek Dimensity Android devices, and on Intel NPUs with '
                  'Windows x64, only',
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
          LiteRtLmNpuTarget(vendor: 'Samsung', soc: 'E9955'),
          // Only LiteRT's OpenVINO stamp is an Intel bundle this runs.
          LiteRtLmNpuTarget(vendor: 'Intel', soc: 'PTL'),
        ]) {
          await expectLater(
            place(target: target),
            _refusal(
              allOf(
                contains('compiled for a ${target.vendor} NPU (${target.soc})'),
                contains(
                  'Qualcomm, Google Tensor, MediaTek and Intel NPUs only',
                ),
              ),
            ),
            reason: '$abi $target',
          );
        }
      }
      expect(host.asked, isEmpty);
    });

    test('a Google Tensor bundle selects only the Google dispatch', () async {
      const tensor = LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5');
      final placement = await place(target: tensor);
      expect(placement.backend, PreferredBackend.npu);
      expect(placement.target, tensor);
      expect(host.asked, ['stack:googleTensor', 'reaches', 'dispatchDir']);
      expect(host.vendors, {NpuStack.googleTensor});
    });

    test('a MediaTek bundle selects only the MediaTek dispatch', () async {
      const mediatek = LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991');
      final placement = await place(target: mediatek);
      expect(placement.backend, PreferredBackend.npu);
      expect(placement.target, mediatek);
      expect(host.asked, ['stack:mediatek', 'reaches', 'dispatchDir']);
      expect(host.vendors, {NpuStack.mediatek});
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
      host.qualcomm = const NpuStackCheck.missing(qualcommNpuNotEnabledReason);
      await expectLater(
        place(),
        _refusal(
          allOf(
            contains('needs the Qualcomm SM8850 NPU'),
            contains('qualcomm_npu: true'),
          ),
        ),
      );
      expect(host.asked, ['stack:qualcomm']);
    });

    test('an unanswerable manifest is not a no: the device is asked', () async {
      host.qualcomm = const NpuStackCheck.unknown('no binding');
      expect((await place()).backend, PreferredBackend.npu);
      expect(host.asked, ['stack:qualcomm', 'reaches', 'dispatchDir']);
    });

    test(
      'on a device without the NPU is refused with the probe\'s reason',
      () async {
        host
          ..reachable = false
          ..noNpuReason = 'this device has no Qualcomm FastRPC';
        await expectLater(
          place(),
          _refusal(
            'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm needs the '
            'Qualcomm SM8850 NPU, and this device has no Qualcomm FastRPC.',
          ),
        );
        expect(host.asked, ['stack:qualcomm', 'reaches']);
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

  group('an Intel (Panther Lake) bundle', () {
    setUp(
      () => host
        ..operatingSystem = 'windows'
        ..abi = 'windows_x64'
        ..dispatchDir = r'C:\Apps\demo',
    );

    test('with npu on Windows x64 runs on the NPU, with the dispatch next to '
        'the executable — only the Intel stack is asked about', () async {
      final placement = await place(target: _ptl);
      expect(placement.backend, PreferredBackend.npu);
      expect(placement.target, _ptl);
      expect(placement.target!.isIntel, isTrue);
      expect(placement.dispatchDir, r'C:\Apps\demo');
      expect(host.asked, ['stack:intel', 'reaches', 'dispatchDir']);
      expect(host.vendors, {NpuStack.intel});
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
                '${os == 'android' ? 'Qualcomm, Google Tensor and MediaTek' : 'Qualcomm'} '
                'NPU bundles only; Intel ones run on windows_x64',
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
      expect(host.asked, ['stack:intel']);
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

  test('the web refusal, word for word: it is assembled from the vendor '
      'table, so a reordered enum or a changed join shows here', () {
    expect(
      liteRtLmWebNpuRefusal,
      'EmbeddingGemma 2 runs on the NPU on Qualcomm Android and Qualcomm Linux '
      'arm64, and on Google Tensor G5/G6 Android devices, and on MediaTek '
      'Dimensity Android devices, and on Intel NPUs with Windows x64, only, '
      'not on the web. Omit preferredBackend here.',
    );
  });

  test('the web refusal names both NPU hosts, Intel included', () {
    expect(
      liteRtLmWebNpuRefusal,
      allOf(
        contains('Qualcomm Android and Qualcomm Linux arm64'),
        contains('Google Tensor G5/G6 Android devices'),
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
      final check = await const LiteRtLmPlatformNpuHost().stack(NpuStack.intel);
      expect(check.bundled, isFalse);
      expect(check.reason, contains('($exeDir)'));
    });

    test('Windows hands LiteRT the executable\'s directory', () async {
      expect(
        await prepareNpuDispatchDir(NpuStack.intel, operatingSystem: 'windows'),
        windowsNpuDispatchDir,
      );
    });
  });
}

final class _FakeHost implements LiteRtLmNpuHost {
  @override
  String operatingSystem = 'android';

  @override
  String abi = 'android_arm64';

  NpuStackCheck qualcomm = const NpuStackCheck.bundled();

  NpuStackCheck googleTensor = const NpuStackCheck.bundled();
  NpuStackCheck mediatek = const NpuStackCheck.bundled();

  NpuStackCheck intel = const NpuStackCheck.bundled();

  String dispatchDir = '/data/app/code_cache/npu';

  bool reachable = true;

  String noNpuReason = 'no NPU';

  NpuDispatchUnavailableException? dispatchError;

  final asked = <String>[];

  /// Every vendor a question named.
  final vendors = <NpuStack>{};

  @override
  Future<NpuStackCheck> stack(NpuStack vendor) async {
    asked.add('stack:${vendor.name}');
    vendors.add(vendor);
    return switch (vendor) {
      NpuStack.qualcomm => qualcomm,
      NpuStack.googleTensor => googleTensor,
      NpuStack.mediatek => mediatek,
      NpuStack.intel => intel,
    };
  }

  @override
  String? unreachable(NpuStack vendor) {
    asked.add('reaches');
    vendors.add(vendor);
    return reachable ? null : noNpuReason;
  }

  @override
  Future<String> prepareDispatchDir(NpuStack vendor) async {
    asked.add('dispatchDir');
    vendors.add(vendor);
    final error = dispatchError;
    if (error != null) throw error;
    return dispatchDir;
  }
}
