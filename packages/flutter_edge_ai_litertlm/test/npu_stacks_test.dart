// The NPU vendor table every per-vendor answer switches over: which stamps a
// vendor owns, which hosts it runs on, and how a list of them reads.

import 'dart:ffi' show Abi;

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmNpuTarget;
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_bundle_info.dart'
    show npuVendorOf;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NpuStack.forStamp', () {
    test('matches the stamp LiteRT writes, in any case', () {
      expect(NpuStack.forStamp('Qualcomm'), NpuStack.qualcomm);
      expect(NpuStack.forStamp('QUALCOMM'), NpuStack.qualcomm);
      expect(NpuStack.forStamp('Google'), NpuStack.googleTensor);
      expect(NpuStack.forStamp('GOOGLE'), NpuStack.googleTensor);
      expect(NpuStack.forStamp('IntelOpenVINO'), NpuStack.intel);
      expect(NpuStack.forStamp('intelopenvino'), NpuStack.intel);
    });

    test('has no vendor for a stamp this package has no dispatch for', () {
      for (final stamp in ['MediaTek', 'Intel', '']) {
        expect(NpuStack.forStamp(stamp), isNull, reason: stamp);
      }
    });

    test('npuVendorOf reads a target the same way', () {
      expect(
        npuVendorOf(const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850')),
        NpuStack.qualcomm,
      );
      expect(
        npuVendorOf(
          const LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
        ),
        NpuStack.googleTensor,
      );
      expect(
        npuVendorOf(const LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991')),
        isNull,
      );
    });
  });

  group('NpuStack.forAbi', () {
    test(
      'Qualcomm and Google on Android, Qualcomm on Linux, Intel on Windows',
      () {
        expect(NpuStack.forAbi('android_arm64'), [
          NpuStack.qualcomm,
          NpuStack.googleTensor,
        ]);
        expect(NpuStack.forAbi('linux_arm64'), [NpuStack.qualcomm]);
        expect(NpuStack.forAbi('windows_x64'), [NpuStack.intel]);
      },
    );

    test('nothing elsewhere', () {
      for (final abi in [
        'android_x64',
        'linux_x64',
        'windows_arm64',
        'macos_arm64',
        'ios_arm64',
      ]) {
        expect(NpuStack.forAbi(abi), isEmpty, reason: abi);
      }
    });
  });

  test('the table itself: every ABI is one Dart knows, every stamp lower '
      'case and owned by one vendor', () {
    // Guards a vendor added later without repeating its strings: a typo in an
    // ABI would silently drop that host, a mixed-case stamp would never match.
    final abiNames = {for (final abi in Abi.values) '$abi'};
    for (final vendor in NpuStack.values) {
      expect(abiNames, containsAll(vendor.abis), reason: vendor.name);
      expect(vendor.abis, isNotEmpty, reason: vendor.name);
      expect(
        vendor.stampVendor,
        vendor.stampVendor.toLowerCase(),
        reason: vendor.name,
      );
    }
    expect(
      NpuStack.values.map((v) => v.stampVendor).toSet(),
      hasLength(NpuStack.values.length),
    );
  });

  test('npuSentenceList reads like a sentence', () {
    expect(npuSentenceList(const []), '');
    expect(npuSentenceList(const ['A']), 'A');
    expect(npuSentenceList(const ['A', 'B']), 'A and B');
    expect(npuSentenceList(const ['A', 'B', 'C']), 'A, B and C');
  });
}
