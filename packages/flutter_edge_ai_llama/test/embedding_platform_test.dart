import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_llama/src/embedding_platform.dart';
import 'package:flutter_test/flutter_test.dart';

import 'embedding_platform_environment_stub.dart'
    if (dart.library.ffi) 'embedding_platform_environment_native.dart';

void main() {
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
