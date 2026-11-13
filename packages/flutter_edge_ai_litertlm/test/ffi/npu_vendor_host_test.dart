// `chooseNpuVendor`: the one rule for which vendor's NPU a load runs on, for
// the LLM engine and the EmbeddingGemma 2 placement alike. The host is a fake:
// every answer it gives is a property of a device a test host is not.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmBundleInfo, LiteRtLmNpuTarget, LiteRtLmSection;
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show NpuDispatchUnavailableException;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');
const _tensorG5 = LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5');
const _mt6991 = LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991');
const _ptl = LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL');

void main() {
  test('a stamped bundle asks only its own vendor, a generic one the vendors '
      'of this ABI', () async {
    for (final target in const [_sm8850, null]) {
      final host = _FakeHost('android_arm64');
      final choice = await chooseNpuVendor(target: target, host: host);
      expect(choice, isA<NpuChosen>(), reason: '$target');
      expect((choice as NpuChosen).vendor, NpuStack.qualcomm);
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
      (LiteRtLmNpuTarget(vendor: 'Samsung', soc: 'E9955'), 'Samsung'),
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
      expect((choice as NpuChosen).vendor, NpuStack.googleTensor);
      expect(host.asked, ['stack:googleTensor', 'probe:googleTensor']);
    },
  );

  test(
    'a MediaTek stamp selects only MediaTek even when Qualcomm is also built',
    () async {
      final host = _FakeHost('android_arm64');
      final choice = await chooseNpuVendor(target: _mt6991, host: host);
      expect(choice, isA<NpuChosen>());
      expect((choice as NpuChosen).vendor, NpuStack.mediatek);
      expect(host.asked, ['stack:mediatek', 'probe:mediatek']);
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
      ], NpuStack.qualcomm),
      throwsA(
        isA<NpuDispatchUnavailableException>().having(
          (e) => e.message,
          'message',
          startsWith('the Qualcomm NPU libraries could not be prepared: '),
        ),
      ),
    );
  });

  group('npuHwMasking', () {
    // The aux stamps and hashes read from the files on the Panther Lake PC
    // (2026-11-13): Intel's public 26B A4B and 12B, the private 12B and
    // Google's E2B `_intel_PTL` stamp tf_lite_aux IntelOpenVINO/PTL; the
    // private 26B's aux carries no stamp (CPU); E2B `_intel_LNL` stamps
    // IntelOpenVINO/LNL. Only the public 26B's aux is listed.
    const ptl = LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL');
    const lnl = LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'LNL');
    const public26b =
        '17accf36c4da07fcdf50abdcc43bd00f6b05d9f2eaee95fa18aaf73e67ebfe28';
    const public26bAuxLength = 5806310;
    const auxBegin = 13249101824;

    LiteRtLmBundleInfo bundle({
      LiteRtLmNpuTarget? text,
      LiteRtLmNpuTarget? aux,
      bool hasAux = true,
      int auxLength = public26bAuxLength,
    }) => LiteRtLmBundleInfo(
      majorVersion: 1,
      minorVersion: 5,
      patchVersion: 0,
      systemMetadata: const {},
      sections: [
        LiteRtLmSection(
          dataType: 'TFLiteModel',
          begin: 32,
          end: 64,
          items: const {'model_type': 'tf_lite_prefill_decode'},
          npuTarget: text,
        ),
        if (hasAux)
          LiteRtLmSection(
            dataType: 'TFLiteModel',
            begin: auxBegin,
            end: auxBegin + auxLength,
            items: const {'model_type': 'tf_lite_aux'},
            npuTarget: aux,
          ),
      ],
      fileLength: auxBegin + auxLength,
    );

    late List<(String, int, int)> hashed;
    Future<String> Function(String, int, int) hashing(String digest) =>
        (path, begin, end) async {
          hashed.add((path, begin, end));
          return digest;
        };
    Future<String> unreadable(String path, int begin, int end) async {
      hashed.add((path, begin, end));
      throw FileSystemException('cannot read', path);
    }

    setUp(() => hashed = []);

    test('the public 26B is listed by its aux length and sha256', () {
      expect(intelBrokenNpuMaskAux.single.length, public26bAuxLength);
      expect(intelBrokenNpuMaskAux.single.sha256, public26b);
    });

    test('Intel, a PTL-stamped aux whose hash is listed: on, explicitly, and '
        'only the aux range is hashed', () async {
      final printed = await printedBy(() async {
        expect(
          await npuHwMasking(
            NpuStack.intel,
            bundle(text: ptl, aux: ptl),
            path: 'pub26b.litertlm',
            sha256OfRange: hashing(public26b),
          ),
          isTrue,
        );
      });
      expect(hashed, [
        ('pub26b.litertlm', auxBegin, auxBegin + public26bAuxLength),
      ]);
      expect(
        printed.where((l) => l.contains('wrong past ~2,048 tokens')),
        hasLength(1),
        reason: 'the log names the file and its known issue',
      );
      expect(
        printed.any((l) => l.contains('gemma4-26B-A4B-it-Intel_PTL_NPU')),
        isTrue,
      );
      // The stamp's case is the compiler's.
      expect(
        await npuHwMasking(
          NpuStack.intel,
          bundle(
            aux: const LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'ptl'),
          ),
          path: 'pub26b.litertlm',
          sha256OfRange: hashing(public26b),
        ),
        isTrue,
      );
    });

    test('Intel, a PTL-stamped aux of the listed length with another hash: '
        'off', () async {
      expect(
        await npuHwMasking(
          NpuStack.intel,
          bundle(text: ptl, aux: ptl),
          path: 'other.litertlm',
          sha256OfRange: hashing('0' * 64),
        ),
        isFalse,
      );
      expect(hashed, hasLength(1));
    });

    test('Intel, a PTL-stamped aux of another length (the 12Bs, E2B '
        '_intel_PTL): off, nothing hashed', () async {
      for (final length in [3888812, 862675, 384432]) {
        expect(
          await npuHwMasking(
            NpuStack.intel,
            bundle(text: ptl, aux: ptl, auxLength: length),
            path: 'x.litertlm',
            sha256OfRange: hashing(public26b),
          ),
          isFalse,
          reason: '$length',
        );
      }
      expect(hashed, isEmpty);
    });

    test('Intel, a Panther Lake bundle whose mask graphs run on the CPU: '
        'off, nothing hashed', () async {
      for (final b in [bundle(text: ptl), bundle(text: ptl, hasAux: false)]) {
        expect(
          await npuHwMasking(
            NpuStack.intel,
            b,
            path: 'x.litertlm',
            sha256OfRange: hashing(public26b),
          ),
          isFalse,
        );
      }
      expect(hashed, isEmpty);
    });

    test('Intel, a Lunar Lake bundle: off, nothing hashed', () async {
      expect(
        await npuHwMasking(
          NpuStack.intel,
          bundle(text: lnl, aux: lnl),
          path: 'x.litertlm',
          sha256OfRange: hashing(public26b),
        ),
        isFalse,
      );
      expect(hashed, isEmpty);
    });

    test('Intel, a non-Intel stamp named PTL: off, nothing hashed', () async {
      expect(
        await npuHwMasking(
          NpuStack.intel,
          bundle(
            aux: const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'PTL'),
          ),
          path: 'x.litertlm',
          sha256OfRange: hashing(public26b),
        ),
        isFalse,
      );
      expect(hashed, isEmpty);
    });

    test('Intel, a file that could not be read: off, nothing hashed', () async {
      expect(
        await npuHwMasking(
          NpuStack.intel,
          null,
          path: 'x.litertlm',
          sha256OfRange: hashing(public26b),
        ),
        isFalse,
      );
      expect(hashed, isEmpty);
    });

    test(
      'Intel, an aux section that cannot be hashed: off, and said',
      () async {
        final printed = await printedBy(() async {
          expect(
            await npuHwMasking(
              NpuStack.intel,
              bundle(aux: ptl),
              path: 'gone.litertlm',
              sha256OfRange: unreadable,
            ),
            isFalse,
          );
        });
        expect(hashed, hasLength(1));
        expect(
          printed.any((l) => l.contains('could not hash the tf_lite_aux')),
          isTrue,
        );
      },
    );

    test('the other vendors leave LiteRT-LM\'s default whatever the file '
        'says, nothing hashed', () async {
      for (final vendor in [
        NpuStack.qualcomm,
        NpuStack.googleTensor,
        NpuStack.mediatek,
      ]) {
        for (final b in [
          null,
          bundle(
            aux: const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
          ),
          // A stamp the vendor does not run cannot reach it (the reader and
          // the vendor choice refuse it first); even so it changes nothing.
          bundle(aux: ptl),
        ]) {
          expect(
            await npuHwMasking(
              vendor,
              b,
              path: 'x.litertlm',
              sha256OfRange: hashing(public26b),
            ),
            isNull,
            reason: vendor.name,
          );
        }
      }
      expect(hashed, isEmpty);
    });

    test('sha256OfFileRange hashes exactly [begin, end) and refuses a file '
        'that ends early', () async {
      final dir = Directory.systemTemp.createTempSync('aux_hash');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/b.litertlm')
        ..writeAsBytesSync(List.generate(100, (i) => i));
      expect(
        await sha256OfFileRange(file.path, 10, 40),
        sha256.convert(List.generate(30, (i) => i + 10)).toString(),
      );
      await expectLater(
        sha256OfFileRange(file.path, 90, 120),
        throwsA(isA<FileSystemException>()),
      );
    });
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
  Future<NpuStackCheck> stack(NpuStack vendor) async {
    asked.add('stack:${vendor.name}');
    return stackCheck;
  }

  @override
  String? unreachable(NpuStack vendor) {
    asked.add('probe:${vendor.name}');
    return unreachableReason;
  }

  @override
  Future<String> prepareDispatchDir(NpuStack vendor) =>
      throw StateError('choosing a vendor prepares nothing');
}

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
