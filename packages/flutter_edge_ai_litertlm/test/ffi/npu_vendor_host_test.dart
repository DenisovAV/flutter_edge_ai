// `chooseNpuVendor`: the one rule for which vendor's NPU a load runs on, for
// the LLM engine and the EmbeddingGemma 2 placement alike. The host is a fake:
// every answer it gives is a property of a device a test host is not.

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmNpuTarget;
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show NpuDispatchUnavailableException;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');
const _tensorG5 = LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5');
const _ptl = LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL');

void main() {
  test('a stamped bundle asks only its own vendor, a generic one the vendors '
      'of this ABI', () async {
    for (final target in const [_sm8850, null]) {
      final host = _FakeHost('android_arm64');
      final choice = await chooseNpuVendor(target: target, host: host);
      expect(choice, isA<NpuChosen>(), reason: '$target');
      expect((choice as NpuChosen).vendor, NpuVendor.qualcomm);
      expect(host.asked, [
        'stack:qualcomm',
        'probe:qualcomm',
      ], reason: '$target');
    }
  });

  test('a vendor this ABI does not run is refused by name, without asking '
      'anything', () async {
    // On android_arm64 an Intel bundle has no candidate: the stamp narrows the
    // ABI's vendors, it never adds one. Qualcomm's stack may well ship here,
    // so the reason names the vendor that is missing.
    for (final (target, vendor) in const [
      (_ptl, 'Intel'),
      (LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991'), 'MediaTek'),
    ]) {
      final host = _FakeHost('android_arm64');
      final choice = await chooseNpuVendor(target: target, host: host);
      expect(
        choice,
        isA<NpuRefused>().having(
          (r) => r.reason,
          'reason',
          'no $vendor NPU dispatch stack ships for android_arm64',
        ),
      );
      expect(host.asked, isEmpty);
    }
  });

  test(
    'a Google stamp selects only Google even when Qualcomm is also built',
    () async {
      final host = _FakeHost('android_arm64');
      final choice = await chooseNpuVendor(target: _tensorG5, host: host);
      expect(choice, isA<NpuChosen>());
      expect((choice as NpuChosen).vendor, NpuVendor.googleTensor);
      expect(host.asked, ['stack:googleTensor', 'probe:googleTensor']);
    },
  );

  test(
    'a host no vendor runs on is refused by its ABI, nothing asked',
    () async {
      for (final abi in ['macos_arm64', 'linux_x64', 'ios_arm64']) {
        final host = _FakeHost(abi);
        final choice = await chooseNpuVendor(target: null, host: host);
        expect(
          choice,
          isA<NpuRefused>().having(
            (r) => r.reason,
            'reason',
            'no NPU dispatch stack ships for $abi',
          ),
          reason: abi,
        );
        expect(host.asked, isEmpty, reason: abi);
      }
    },
  );

  test('a stack the build does not carry is the reason, and the device is '
      'not probed', () async {
    final host = _FakeHost(
      'android_arm64',
      stackCheck: const NpuStackCheck.missing('the app did not opt in'),
    );
    final choice = await chooseNpuVendor(target: _sm8850, host: host);
    expect(
      choice,
      isA<NpuRefused>().having(
        (r) => r.reason,
        'reason',
        'the app did not opt in',
      ),
    );
    expect(host.asked, ['stack:qualcomm']);
  });

  test('a stack the manifest cannot vouch for goes on to the device', () async {
    final host = _FakeHost(
      'android_arm64',
      stackCheck: const NpuStackCheck.unknown('no binding'),
    );
    final choice = await chooseNpuVendor(target: null, host: host);
    expect(choice, isA<NpuChosen>());
    expect(host.asked, ['stack:qualcomm', 'probe:qualcomm']);
  });

  test(
    "the device's answer is the reason when it cannot run the stack",
    () async {
      final host = _FakeHost(
        'windows_x64',
        unreachableReason: 'no Intel NPU here',
      );
      final choice = await chooseNpuVendor(target: null, host: host);
      expect(
        choice,
        isA<NpuRefused>().having(
          (r) => r.reason,
          'reason',
          'no Intel NPU here',
        ),
      );
      expect(host.asked, ['stack:intel', 'probe:intel']);
    },
  );

  test('a channel this isolate cannot reach is a stack that could not be '
      'prepared, not a raw Error', () async {
    // No binding here, as in a background isolate without
    // BackgroundIsolateBinaryMessenger: the channel throws an Error.
    await expectLater(
      prepareAndroidNpuDispatchDir(const [
        'LiteRtDispatch_Qualcomm',
      ], NpuVendor.qualcomm),
      throwsA(
        isA<NpuDispatchUnavailableException>().having(
          (e) => e.message,
          'message',
          startsWith('the Qualcomm NPU libraries could not be prepared: '),
        ),
      ),
    );
  });

  test('each vendor says whether it turns the HW mask update path off', () {
    expect(npuDisablesHwMasking(NpuVendor.qualcomm), isFalse);
    expect(npuDisablesHwMasking(NpuVendor.googleTensor), isFalse);
    expect(npuDisablesHwMasking(NpuVendor.intel), isTrue);
  });
}

final class _FakeHost implements LiteRtLmNpuHost {
  _FakeHost(
    this.abi, {
    this.stackCheck = const NpuStackCheck.bundled(),
    this.unreachableReason,
  });

  @override
  final String abi;

  @override
  String get operatingSystem => abi.split('_').first;

  final NpuStackCheck stackCheck;
  final String? unreachableReason;
  final asked = <String>[];

  @override
  Future<NpuStackCheck> stack(NpuVendor vendor) async {
    asked.add('stack:${vendor.name}');
    return stackCheck;
  }

  @override
  String? unreachable(NpuVendor vendor) {
    asked.add('probe:${vendor.name}');
    return unreachableReason;
  }

  @override
  Future<String> prepareDispatchDir(NpuVendor vendor) =>
      throw StateError('choosing a vendor prepares nothing');
}
