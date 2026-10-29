// An Android emulator's run is not device evidence: registry_evidence.dart
// marks it a simulator, which `registry.dart evidence` refuses.

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/registry_evidence.dart';

void main() {
  bool? emulator(Map<String, String> props, [Set<String> nodes = const {}]) =>
      looksLikeAndroidEmulator(
        property: (name) => props[name],
        exists: nodes.contains,
      );
  const phone = 'google/husky/husky:15/AP4A/1:user/release-keys';

  test('an emulator by its properties or device nodes', () {
    expect(
      emulator({'ro.build.fingerprint': phone, 'ro.boot.qemu': '1'}),
      isTrue,
    );
    expect(
      emulator({'ro.build.fingerprint': phone, 'ro.kernel.qemu': '1'}),
      isTrue,
    );
    expect(
      emulator({'ro.build.fingerprint': phone, 'ro.hardware': 'ranchu'}),
      isTrue,
    );
    // A current arm64 AVD: no "generic" in its fingerprint.
    expect(
      emulator({
        'ro.build.fingerprint':
            'google/sdk_gphone64_arm64/emu64a:15/AE3A/1:user/release-keys',
      }),
      isTrue,
    );
    expect(
      emulator({
        'ro.build.fingerprint': phone,
        'ro.product.model': 'sdk_gphone64_arm64',
      }),
      isTrue,
    );
    expect(
      emulator({'ro.build.fingerprint': phone}, {'/dev/goldfish_pipe'}),
      isTrue,
    );
  });

  test('a phone is not one', () {
    expect(
      emulator({
        'ro.build.fingerprint': phone,
        'ro.boot.qemu': '0',
        'ro.hardware': 'husky',
        'ro.product.model': 'Pixel 8 Pro',
      }),
      isFalse,
    );
  });

  test('properties that cannot be read are no answer, not a device', () {
    expect(emulator({}), isNull);
  });
}
