import 'dart:ffi';

/// The native host, as `Abi` names it (`macos_arm64`).
String hostAbi() => Abi.current().toString();
