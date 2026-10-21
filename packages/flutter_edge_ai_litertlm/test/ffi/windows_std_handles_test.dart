import 'package:flutter_edge_ai_litertlm/src/ffi/windows_std_handles.dart';
import 'package:flutter_test/flutter_test.dart';

// Handle values for the fake process. Only the console answers
// GetConsoleMode; NUL is a character device that does not (the real call is
// held to that in windows_std_handles_windows_test.dart).
const _console = 0x254;
const _file = 0x70;
const _otherFile = 0x88;
const _nul = 0x90;
const _noHandle = -2;

class _FakeProcess {
  _FakeProcess({
    required this.crt,
    required this.std,
    this.duplicateFails = false,
    this.setFails = false,
  });

  /// fd → `_get_osfhandle(fd)`.
  final Map<int, int> crt;

  /// STD_*_HANDLE id → GetStdHandle.
  final Map<int, int> std;
  final bool duplicateFails;
  final bool setFails;

  final duplicated = <int>[];
  final closed = <int>[];
  int _next = 0x1000;

  StdHandleCalls get calls => (
    crtHandle: (fd) => crt[fd] ?? -1,
    getStdHandle: (which) => std[which] ?? 0,
    isConsole: (h) => h == _console,
    duplicate: (h) {
      if (duplicateFails) return 0;
      duplicated.add(h);
      return _next++;
    },
    setStdHandle: (which, h) {
      if (setFails) return false;
      std[which] = h;
      return true;
    },
    closeHandle: closed.add,
  );
}

void main() {
  test('stderr redirected while AttachConsole put the console in its place: '
      'repoints STD_ERROR only, at a duplicate', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    expect(alignStdHandles(p.calls), [stdErrorHandle]);
    expect(p.duplicated, [_file]);
    expect(p.std[stdErrorHandle], isNot(_file));
    expect(p.std[stdErrorHandle], isNot(_console));
    expect(p.std[stdOutputHandle], _console);
  });

  test('both redirected: repoints both', () {
    final p = _FakeProcess(
      crt: {1: _otherFile, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    expect(alignStdHandles(p.calls), [stdOutputHandle, stdErrorHandle]);
    expect(p.duplicated, [_otherFile, _file]);
  });

  test('2>NUL: a non-console fd is repointed to like a file', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _nul},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    expect(alignStdHandles(p.calls), [stdErrorHandle]);
    expect(p.duplicated, [_nul]);
  });

  test('a second call changes nothing', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    alignStdHandles(p.calls);
    expect(alignStdHandles(p.calls), isEmpty);
    expect(p.duplicated, [_file]);
  });

  test('handles that already agree (flutter run, pipes passed with '
      'STARTF_USESTDHANDLES): no change', () {
    final p = _FakeProcess(
      crt: {1: _otherFile, 2: _file},
      std: {stdOutputHandle: _otherFile, stdErrorHandle: _file},
    );
    expect(alignStdHandles(p.calls), isEmpty);
  });

  test('no handle behind the fd (launched from Explorer): no change', () {
    final p = _FakeProcess(
      crt: {1: _noHandle, 2: _noHandle},
      std: {stdOutputHandle: 0, stdErrorHandle: 0},
    );
    expect(alignStdHandles(p.calls), isEmpty);
  });

  test('a closed fd (-1): no change', () {
    final p = _FakeProcess(
      crt: {},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    expect(alignStdHandles(p.calls), isEmpty);
  });

  test('the fd is a console itself (the debugger runner reopens CONOUT\$): '
      'no change', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _console},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
    );
    expect(alignStdHandles(p.calls), isEmpty);
  });

  test('a standard handle that is not a console was set on purpose: '
      'left alone', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _otherFile},
    );
    expect(alignStdHandles(p.calls), isEmpty);
  });

  test('no standard handle at all: left alone', () {
    final p = _FakeProcess(
      crt: {1: _otherFile, 2: _file},
      std: {stdOutputHandle: 0, stdErrorHandle: -1},
    );
    expect(alignStdHandles(p.calls), isEmpty);
    expect(p.duplicated, isEmpty);
  });

  test('a failed DuplicateHandle changes nothing', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
      duplicateFails: true,
    );
    expect(alignStdHandles(p.calls), isEmpty);
    expect(p.std[stdErrorHandle], _console);
  });

  test('a failed SetStdHandle closes the duplicate', () {
    final p = _FakeProcess(
      crt: {1: _console, 2: _file},
      std: {stdOutputHandle: _console, stdErrorHandle: _console},
      setFails: true,
    );
    expect(alignStdHandles(p.calls), isEmpty);
    expect(p.closed, hasLength(1));
    expect(p.std[stdErrorHandle], _console);
  });
}
