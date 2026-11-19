// ORT-GenAI (since 0.17.0) and ONNX Runtime (official builds since 1.28) ship
// Microsoft's telemetry on by default; both clients turn it off before their
// library is opened, and leave a value the app set alone.
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_ffi_client.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/ort_telemetry.dart';
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
    disableOrtTelemetry();
    expect(current(), '1');
  }, skip: posix ? false : 'POSIX environment; Windows is checked on a PC');

  test('keeps a value the app already set', () {
    set('0');
    disableOrtTelemetry();
    expect(current(), '0');
  }, skip: posix ? false : 'POSIX environment; Windows is checked on a PC');

  test('the embedding client sets it before it opens ONNX Runtime', () {
    unset();
    expect(current(), isNull);
    // Without the bundle or an override the open fails on a bare host VM;
    // the variable must already be set by then.
    try {
      OrtFfiClient();
    } catch (_) {}
    expect(current(), '1');
  }, skip: posix ? false : 'POSIX environment; Windows is checked on a PC');
}
