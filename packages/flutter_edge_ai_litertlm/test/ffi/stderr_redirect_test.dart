@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/stderr_redirect.dart';
import 'package:flutter_test/flutter_test.dart';

final _libc = DynamicLibrary.process();
final _pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('pipe');
final _dup2 = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'dup2',
    );
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');

/// A pipe as (read end, write end).
(int, int) _newPipe() {
  final fds = calloc<Int32>(2);
  try {
    expect(_pipe(fds), 0);
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

void _send(int fd, String s) {
  final bytes = utf8.encode(s);
  final buf = calloc<Uint8>(bytes.length)
    ..asTypedList(bytes.length).setAll(0, bytes);
  try {
    expect(_write(fd, buf, bytes.length), bytes.length);
  } finally {
    calloc.free(buf);
  }
}

/// What one read returns; '' at end of file (no writer left).
String _receive(int fd) {
  final buf = calloc<Uint8>(256);
  try {
    final n = _read(fd, buf, 256);
    expect(n, greaterThanOrEqualTo(0));
    return utf8.decode(buf.asTypedList(n));
  } finally {
    calloc.free(buf);
  }
}

void main() {
  // The runner's own stdout cannot be handed to the code under test, so a
  // pipe stands in for it, and a second pipe for the native log file. The
  // fake redirect does what stream_proxy_redirect_stderr does: dup2 the log
  // onto stdout and onto stderr (here a third pipe's write end).
  test('stdout is put back after a redirect that moved it, stderr is not', () {
    final (stdoutRead, stdoutFd) = _newPipe();
    final (logRead, logWrite) = _newPipe();
    final (stderrRead, stderrFd) = _newPipe();
    addTearDown(() {
      for (final fd in [
        stdoutRead,
        stdoutFd,
        logRead,
        logWrite,
        stderrRead,
        stderrFd,
      ]) {
        _close(fd);
      }
    });

    final r = redirectStderrKeepingStdout(() {
      _dup2(logWrite, stdoutFd);
      _dup2(logWrite, stderrFd);
      return 0;
    }, stdoutFd: stdoutFd);

    expect(r, (rc: 0, restoreError: null));
    _send(stdoutFd, 'print line');
    expect(_receive(stdoutRead), 'print line');
    _send(stderrFd, 'native log line');
    expect(_receive(logRead), 'native log line');
  });

  test('a stdout that cannot be saved is not redirected', () {
    var called = false;
    final r = redirectStderrKeepingStdout(() {
      called = true;
      return 0;
    }, stdoutFd: -1);

    expect(r, (rc: null, restoreError: null));
    expect(called, isFalse);
  });

  test("returns the redirect's own status", () {
    final (stdoutRead, stdoutFd) = _newPipe();
    addTearDown(() {
      _close(stdoutRead);
      _close(stdoutFd);
    });

    final r = redirectStderrKeepingStdout(() => 1, stdoutFd: stdoutFd);

    expect(r, (rc: 1, restoreError: null));
  });
}
