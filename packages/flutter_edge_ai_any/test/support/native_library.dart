import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai_any/src/ffi/any_shim_bindings.dart';

/// The hook's target name for this host, as in hook/build.dart.
String hostTarget() {
  final os = Platform.operatingSystem;
  final arch = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    _ => 'x86_64',
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
    final hook = File('hook/build.dart').readAsStringSync();
    if (hook.contains("'any-shim-$target.tar.gz'")) return null;
    return 'libany_shim is not built for $target and no native-any release '
        'pins it yet; run native/any_shim/build.sh $target '
        '(the hook then registers native/any_shim/prebuilt/$target). '
        'Loader said: ${e.message}';
  }
}

/// The dead nodeconf the Go tests use: any-sync-sdk's local test network
/// with every address on a closed port.
String deadNodeConf() =>
    File('native/any_shim/testdata/nodeconf-dead.yml').readAsStringSync();
