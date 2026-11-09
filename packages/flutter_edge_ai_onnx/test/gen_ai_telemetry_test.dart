// ORT-GenAI 0.17.0 ships Microsoft's telemetry on by default; the client turns
// it off before the library is opened, and leaves a value the app set alone.
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _variable = 'ORT_DISABLE_TELEMETRY';

typedef _Setenv = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int);
typedef _Unsetenv = int Function(ffi.Pointer<Utf8>);
typedef _Getenv = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

void main() {
  final posix = Platform.isLinux || Platform.isMacOS;
  final proc = posix ? ffi.DynamicLibrary.process() : null;

  void unset() {
    final name = _variable.toNativeUtf8();
    proc!.lookupFunction<ffi.Int32 Function(ffi.Pointer<Utf8>), _Unsetenv>(
      'unsetenv',
    )(name);
    calloc.free(name);
  }

  /// What the C runtime sees; `Platform.environment` is a snapshot.
  String? current() {
    final name = _variable.toNativeUtf8();
    final found = proc!
        .lookupFunction<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>), _Getenv>(
          'getenv',
        )(name);
    calloc.free(name);
    return found == ffi.nullptr ? null : found.toDartString();
  }

  void set(String value) {
    final name = _variable.toNativeUtf8();
    final v = value.toNativeUtf8();
    proc!.lookupFunction<
      ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32),
      _Setenv
    >('setenv')(name, v, 1);
    calloc.free(name);
    calloc.free(v);
  }

  tearDown(() {
    if (posix) unset();
  });

  test('sets ORT_DISABLE_TELEMETRY=1 when the app did not', () {
    unset();
    expect(current(), isNull);
    disableGenAiTelemetry();
    expect(current(), '1');
  }, skip: posix ? false : 'POSIX environment; Windows is checked on a PC');

  test('keeps a value the app already set', () {
    set('0');
    disableGenAiTelemetry();
    expect(current(), '0');
  }, skip: posix ? false : 'POSIX environment; Windows is checked on a PC');
}
