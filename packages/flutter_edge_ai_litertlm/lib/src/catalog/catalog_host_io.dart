import 'dart:ffi' show Abi;

/// This host as `Abi.current()` names it: `android_arm64`, `windows_x64`, …
String? get catalogHostAbi => '${Abi.current()}';
