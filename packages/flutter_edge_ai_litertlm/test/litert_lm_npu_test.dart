// `placeLiteRtLmEmbedder`: where an EmbeddingGemma 2 bundle runs, and every
// refusal (owner-approved design, 2026-10-12) — nothing switches backend on
// its own, because NPU and CPU vectors are not interchangeable. The host is a
// fake: every answer it gives is a property of a device a test host is not.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_npu.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show NpuDispatchUnavailableException;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = 'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm';
const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');

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
              contains('SM8850, SM8650, QCS8275 are verified'),
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
      ('windows', 'windows_x64'),
      ('linux', 'linux_x64'),
      ('android', 'android_x64'),
    ]) {
      test('with npu on $abi is refused before anything is asked', () async {
        host
          ..operatingSystem = os
          ..abi = abi;
        await expectLater(
          place(),
          _refusal(
            allOf(
              contains('Qualcomm Android and Qualcomm Linux arm64 only'),
              contains('this is $os ($abi)'),
              contains('generic EmbeddingGemma 2 bundle'),
            ),
          ),
        );
        expect(host.asked, isEmpty);
      });
    }

    test('compiled for another vendor is refused, even on Android', () async {
      for (final target in const [
        LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
        LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991'),
        LiteRtLmNpuTarget(vendor: 'Intel', soc: 'PTL'),
      ]) {
        await expectLater(
          place(target: target),
          _refusal(
            allOf(
              contains('compiled for a ${target.vendor} NPU (${target.soc})'),
              contains('Qualcomm NPUs only'),
            ),
          ),
        );
      }
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
          ..hasNpu = false
          ..noNpuReason = 'this device has no Qualcomm FastRPC';
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
}

final class _FakeHost implements LiteRtLmNpuHost {
  @override
  String operatingSystem = 'android';

  @override
  String abi = 'android_arm64';

  NpuStackCheck stack = const NpuStackCheck.bundled();

  bool _hasNpu = true;

  @override
  String noNpuReason = 'no NPU';

  NpuDispatchUnavailableException? dispatchError;

  final asked = <String>[];

  set hasNpu(bool value) => _hasNpu = value;

  @override
  bool get hasNpu {
    asked.add('hasNpu');
    return _hasNpu;
  }

  @override
  Future<NpuStackCheck> qualcommStack() async {
    asked.add('stack');
    return stack;
  }

  @override
  Future<String> prepareDispatchDir() async {
    asked.add('dispatchDir');
    final error = dispatchError;
    if (error != null) throw error;
    return '/data/app/code_cache/npu';
  }
}
