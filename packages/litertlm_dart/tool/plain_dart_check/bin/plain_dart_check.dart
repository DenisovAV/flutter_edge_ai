// Loads litertlm_dart's native libraries in a plain Dart program, no model:
// what CI runs after `dart run` and after `dart build cli` of a bundle moved
// elsewhere. Prints the code assets' directory it resolved and the native
// release, and exits 0 only when LiteRtLm, LiteRt and StreamProxy loaded and
// a client got as far as the (missing) model.
//
// Internal to the repository's CI: it reads the runtime's private library
// lookup, which the published API does not expose.
import 'dart:io';

import 'package:litertlm_dart/litert_bindings.dart' show LiteRtBindings;
// ignore: implementation_imports — the client, to check a load gets as far as the model.
import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
// ignore: implementation_imports — the plain LiteRtLm opener under test.
import 'package:litertlm_dart/src/ffi/litert_lm_library.dart';
// ignore: implementation_imports — the code-asset directory lookup under test.
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
// ignore: implementation_imports — tells a library-load failure from a model failure.
import 'package:litertlm_dart/src/runtime/load_errors.dart'
    show LibraryLoadFailure;
// ignore: implementation_imports — prints the native release the hook bundled.
import 'package:litertlm_dart/src/runtime/native_release.dart';

Future<void> main() async {
  stdout.writeln('executable: ${Platform.resolvedExecutable}');
  stdout.writeln('native release: $liteRtLmNativeReleaseTag');
  final dir = nativeAssetDir;
  stdout.writeln('code assets: $dir');
  if (dir == null) {
    stderr.writeln('FAIL: no code assets of litertlm_dart found');
    exit(1);
  }
  openLiteRtLmLibrary();
  stdout.writeln('opened ${nativeAssetPath(dir, liteRtLmAssetFile)}');
  LiteRtBindings.open();
  stdout.writeln('opened the LiteRT C API');
  try {
    await LiteRtLmFfiClient().initialize(modelPath: '/no/such/model.litertlm');
    stderr.writeln('FAIL: a client initialized without a model');
    exit(1);
  } on LibraryLoadFailure catch (e) {
    stderr.writeln('FAIL: the client did not load the libraries: $e');
    exit(1);
  } catch (e) {
    // The libraries loaded; only the model is missing.
    stdout.writeln('client: libraries loaded, model refused as expected');
  }
  stdout.writeln('OK');
}
