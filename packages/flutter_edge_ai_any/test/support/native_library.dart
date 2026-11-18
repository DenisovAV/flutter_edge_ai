import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai_any/src/ffi/any_shim_bindings.dart';

/// The hook's target name for this host, as in hook/build.dart.
String hostTarget() {
  final os = Platform.operatingSystem;
  final arch = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    Abi.macosX64 || Abi.linuxX64 || Abi.windowsX64 => 'x86_64',
    final abi => throw UnsupportedError('no libany_shim target for $abi'),
  };
  return '${os}_$arch';
}

/// Null when libany_shim is loadable here. Otherwise the reason to skip the
/// native suites, but only while no release pins an archive for this host:
/// once hook/build.dart has a checksum for it, a missing library is a broken
/// build and the suites must fail, so this returns null and lets them.
String? nativeSkipReason() {
  try {
    any_shim_abi_version();
    return null;
  } on ArgumentError catch (e) {
    final target = hostTarget();
    if (pinnedTargets().contains(target)) return null;
    return 'libany_shim is not built for $target and no native-any release '
        'pins it yet; run native/any_shim/build.sh $target '
        '(the hook then registers native/any_shim/prebuilt/$target). '
        'Loader said: ${e.message}';
  }
}

/// The targets hook/build.dart pins an archive checksum for.
Set<String> pinnedTargets() {
  final hook = File('hook/build.dart').readAsStringSync();
  final map = RegExp(
    r'const Map<String, String> _checksums = \{(.*?)\};',
    dotAll: true,
  ).firstMatch(hook);
  if (map == null) throw StateError('hook/build.dart has no _checksums map');
  return RegExp(
    r'any-shim-([a-z0-9_]+)\.tar\.gz',
  ).allMatches(map.group(1)!).map((m) => m.group(1)!).toSet();
}

/// The dead nodeconf the Go tests use: any-sync-sdk's local test network
/// with every address on a closed port.
String deadNodeConf() =>
    File('native/any_shim/testdata/nodeconf-dead.yml').readAsStringSync();
