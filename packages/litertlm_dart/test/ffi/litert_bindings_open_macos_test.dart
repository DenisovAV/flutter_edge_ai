// LiteRtBindings.open() on a macOS host loads a copy of libLiteRtLm from disk
// (#689): flutter_tester is not inside an app, so after LiteRtLm.framework
// the local prebuilts and the build hook's cache are tried.
//
// Its own file, so the library it loads stays out of the process of
// macos_load_error_test.dart, whose real-Mach-O test loads its own copy.

import 'dart:ffi';
import 'dart:io';

import 'package:litertlm_dart/src/runtime/host_native_library.dart';
import 'package:litertlm_dart/src/ffi/litert_bindings.dart';
import 'package:litertlm_dart/src/ffi/macos_load_error.dart'
    show debugUseHostLiteRtLmCopies;
import 'package:test/test.dart';

void main() {
  final String? copy = Platform.isMacOS && Abi.current() == Abi.macosArm64
      ? firstExistingPath(
          hostNativeLibraryCandidates(
            libFileName: hostNativeLibraryFileName('LiteRtLm'),
          ),
        )
      : null;

  test(
    'LiteRtBindings.open() loads a host copy of libLiteRtLm',
    () {
      // dart test is a plain Dart program: it opens its code asset, and only
      // this package's own tests may fall back to a host copy.
      debugUseHostLiteRtLmCopies = true;
      addTearDown(() => debugUseHostLiteRtLmCopies = false);
      expect(LiteRtBindings.open, returnsNormally);
    },
    skip: copy == null
        ? 'macOS arm64 with a libLiteRtLm in the hook cache only'
        : false,
  );
}
