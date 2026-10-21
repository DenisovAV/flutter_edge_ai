@TestOn('windows')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/windows_std_handles.dart';
import 'package:flutter_test/flutter_test.dart';

// The real Win32 calls alignStdHandles is given: what the fake in
// windows_std_handles_test.dart assumes of them.
void main() {
  test('NUL is a character device that is not a console', () {
    final calls = win32StdHandleCalls();
    expect(calls, isNotNull, reason: 'the test runner loads ucrtbase.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createFile = kernel32
        .lookupFunction<
          IntPtr Function(
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Uint32,
            Uint32,
            IntPtr,
          ),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    final getFileType = kernel32
        .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
          'GetFileType',
        );
    const genericWrite = 0x40000000, shareReadWrite = 0x3, openExisting = 3;
    final name = 'NUL'.toNativeUtf16();
    final nul = createFile(
      name,
      genericWrite,
      shareReadWrite,
      nullptr,
      openExisting,
      0,
      0,
    );
    calloc.free(name);
    expect(nul, isNot(-1));
    try {
      const fileTypeChar = 2;
      // What GetFileType alone cannot tell apart from a console.
      expect(getFileType(nul), fileTypeChar);
      expect(calls!.isConsole(nul), isFalse);
    } finally {
      calls!.closeHandle(nul);
    }
  });
}
