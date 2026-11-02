import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_llama/src/embedding_platform.dart';
import 'package:flutter_test/flutter_test.dart';

import 'embedding_platform_environment_stub.dart'
    if (dart.library.ffi) 'embedding_platform_environment_native.dart';

void main() {
  for (final (name, android, ios, macosX64, udid, expected)
      in <(String, bool, bool, bool, String?, bool)>[
        ('Android', true, false, false, null, true),
        ('iOS simulator', false, true, false, 'simulator-uuid', true),
        ('physical iOS', false, true, false, null, false),
        ('macOS x64/Rosetta', false, false, true, null, true),
        ('other native hosts', false, false, false, null, false),
      ]) {
    test('automatic CPU placement: $name', () {
      expect(
        nativeEmbeddingAutoUsesCpu(
          isAndroid: android,
          isIOS: ios,
          isMacosX64: macosX64,
          readVariable: (_) => udid,
        ),
        expected,
      );
      if (macosX64) {
        expect(
          nativeEmbeddingGpuRefusal(
            isAndroid: android,
            isIOS: ios,
            readVariable: (_) => fail('macOS must not query simulator'),
          ),
          isNull,
          reason: 'Automatic CPU selection must not refuse explicit GPU.',
        );
      }
    }, skip: kIsWeb);
  }
  test('Web has no native automatic placement policy', () {
    expect(nativeEmbeddingAutoUsesCpu(), isFalse);
  }, skip: !kIsWeb);

  test('Android refuses explicit GPU without simulator environment access', () {
    expect(
      nativeEmbeddingGpuRefusal(
        isAndroid: true,
        isIOS: false,
        readVariable: (_) => fail('Android must not query simulator'),
      ),
      contains('Android'),
    );
  }, skip: kIsWeb);
  for (final udid in <String?>[null, '', 'simulator-uuid']) {
    test('iOS simulator detection uses nonempty libc environment: $udid', () {
      expect(
        nativeEmbeddingGpuRefusal(
          isAndroid: false,
          isIOS: true,
          readVariable: (name) {
            expect(name, 'SIMULATOR_UDID');
            return udid;
          },
        ),
        udid == null || udid.isEmpty ? isNull : contains('iOS simulators'),
      );
    }, skip: kIsWeb);
  }
  test('libc environment probe agrees with the host simulator variable', () {
    expect(
      nativeEmbeddingGpuRefusal(isAndroid: false, isIOS: true),
      hostHasSimulatorUdid ? contains('iOS simulators') : isNull,
    );
  }, skip: !supportsLibcProbe);
  test('other native hosts never query simulator environment', () {
    expect(
      nativeEmbeddingGpuRefusal(
        isAndroid: false,
        isIOS: false,
        readVariable: (_) => fail('non-iOS must not query simulator'),
      ),
      isNull,
    );
  });
}
