// The NPU vendor table every per-vendor answer switches over: which stamps a
// vendor owns, which hosts it runs on, and how a list of them reads.

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmNpuTarget;
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_bundle_info.dart'
    show npuVendorOf;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NpuVendor.forStamp', () {
    test('matches the stamp LiteRT writes, in any case', () {
      expect(NpuVendor.forStamp('Qualcomm'), NpuVendor.qualcomm);
      expect(NpuVendor.forStamp('QUALCOMM'), NpuVendor.qualcomm);
      expect(NpuVendor.forStamp('IntelOpenVINO'), NpuVendor.intel);
      expect(NpuVendor.forStamp('intelopenvino'), NpuVendor.intel);
    });

    test('has no vendor for a stamp this package has no dispatch for', () {
      for (final stamp in ['MediaTek', 'Google', 'Intel', '']) {
        expect(NpuVendor.forStamp(stamp), isNull, reason: stamp);
      }
    });

    test('npuVendorOf reads a target the same way', () {
      expect(
        npuVendorOf(const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850')),
        NpuVendor.qualcomm,
      );
      expect(
        npuVendorOf(const LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991')),
        isNull,
      );
    });
  });

  group('NpuVendor.forAbi', () {
    test('Qualcomm on Android and Linux arm64, Intel on Windows x64', () {
      expect(NpuVendor.forAbi('android_arm64'), [NpuVendor.qualcomm]);
      expect(NpuVendor.forAbi('linux_arm64'), [NpuVendor.qualcomm]);
      expect(NpuVendor.forAbi('windows_x64'), [NpuVendor.intel]);
    });

    test('nothing elsewhere', () {
      for (final abi in [
        'android_x64',
        'linux_x64',
        'windows_arm64',
        'macos_arm64',
        'ios_arm64',
      ]) {
        expect(NpuVendor.forAbi(abi), isEmpty, reason: abi);
      }
    });

    test('runsOn follows the hosts, by operating system', () {
      expect(NpuVendor.qualcomm.runsOn('android'), isTrue);
      expect(NpuVendor.qualcomm.runsOn('linux'), isTrue);
      expect(NpuVendor.qualcomm.runsOn('windows'), isFalse);
      expect(NpuVendor.intel.runsOn('windows'), isTrue);
      expect(NpuVendor.intel.runsOn('macos'), isFalse);
    });
  });

  test('npuSentenceList reads like a sentence', () {
    expect(npuSentenceList(const []), '');
    expect(npuSentenceList(const ['A']), 'A');
    expect(npuSentenceList(const ['A', 'B']), 'A and B');
    expect(npuSentenceList(const ['A', 'B', 'C']), 'A, B and C');
  });
}
