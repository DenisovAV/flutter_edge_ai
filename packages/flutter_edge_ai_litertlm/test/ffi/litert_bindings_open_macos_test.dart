// LiteRtBindings.open() on a macOS host loads a copy of libLiteRtLm from disk
// (#689): flutter_tester is not inside an app, so after LiteRtLm.framework
// the local prebuilts and the build hook's cache are tried.
//
// Its own file, so the real constraint provider never loads into the process
// of macos_load_error_test.dart, whose real-Mach-O test needs it absent.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/engine_io.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

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
    () => expect(LiteRtBindings.open, returnsNormally),
    skip: copy == null
        ? 'macOS arm64 with a libLiteRtLm in the hook cache only'
        : false,
  );
}
