import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../memory_read_exception.dart';
import '../memory_snapshot.dart';

// Byte offsets in the 64-bit layouts of `PROCESS_MEMORY_COUNTERS` (`psapi.h`)
// and its two extensions. Each struct begins with the one before it, so one
// buffer serves all three: a larger `cb` just asks for more fields.
//
//   PROCESS_MEMORY_COUNTERS      cb 72   ... PagefileUsage (56), PeakPagefileUsage (64)
//   PROCESS_MEMORY_COUNTERS_EX   cb 80   + PrivateUsage (72)
//   PROCESS_MEMORY_COUNTERS_EX2  cb 96   + PrivateWorkingSetSize (80), SharedCommitUsage (88)

/// `sizeof(PROCESS_MEMORY_COUNTERS)`: the struct every Windows version fills.
const int processMemoryCountersSize = 72;

/// `sizeof(PROCESS_MEMORY_COUNTERS_EX2)`: the one with `PrivateWorkingSetSize`.
const int processMemoryCountersEx2Size = 96;

/// Offset of `WorkingSetSize`.
const int workingSetSizeOffset = 16;

/// Offset of `PagefileUsage`: the process's commit charge, which Microsoft
/// documents as the same number as `PrivateUsage` of the `_EX` struct.
const int pagefileUsageOffset = 56;

/// Offset of `PeakPagefileUsage`: the highest commit charge since the process
/// started.
const int peakPagefileUsageOffset = 64;

/// Offset of `PrivateWorkingSetSize`, the first field of `_EX2` past `_EX`.
const int privateWorkingSetSizeOffset = 80;

/// Offset of `ullAvailPhys` in `MEMORYSTATUSEX`.
const int availPhysOffset = 16;

/// `sizeof(MEMORYSTATUSEX)`.
const int memoryStatusExSize = 64;

/// The byte the buffer is filled with before a call. A field the OS did not
/// write still reads as eight of these, which no real byte count can be
/// (`0xABAB_ABAB_ABAB_ABAB` is about 12 exabytes).
const int unwrittenByte = 0xAB;
const int _unwritten64 = 0xABABABABABABABAB;

/// The numbers a Windows reply holds, before they are named by snapshot field.
final class WindowsProcessCounters {
  const WindowsProcessCounters({
    required this.commitBytes,
    required this.peakCommitBytes,
    required this.fileBackedBytes,
  });

  /// `PagefileUsage` (= `PrivateUsage`): memory the process has committed.
  final int commitBytes;

  /// `PeakPagefileUsage`: the highest [commitBytes] since the process started.
  final int peakCommitBytes;

  /// `WorkingSetSize - PrivateWorkingSetSize`, or null when the OS did not
  /// write `PrivateWorkingSetSize` (a Windows older than the `_EX2` struct).
  final int? fileBackedBytes;
}

/// Fills [buffer], which holds [processMemoryCountersEx2Size] bytes, with the
/// unwritten marker.
void markUnwritten(Uint8List buffer) =>
    buffer.fillRange(0, buffer.length, unwrittenByte);

/// Reads the counters out of [info] after a successful call that was given a
/// buffer filled by [markUnwritten] and a size of [cb].
///
/// A field the call did not write still holds the marker: that is how an OS
/// that predates `PrivateWorkingSetSize` is told apart from a process whose
/// value is genuinely small. Throws [MemoryReadException] when a field every
/// Windows writes is still unwritten. A private working set larger than the
/// working set (the kernel reads the two separately, so a trim between them can
/// produce it) leaves only `fileBackedBytes` null; commit stays valid.
WindowsProcessCounters windowsCountersFromReply(ByteData info, int cb) {
  if (cb != processMemoryCountersSize && cb != processMemoryCountersEx2Size) {
    throw ArgumentError.value(cb, 'cb', 'not a PROCESS_MEMORY_COUNTERS size');
  }
  if (info.lengthInBytes < cb) {
    throw MemoryReadException(
      'a buffer of ${info.lengthInBytes} bytes cannot hold $cb',
    );
  }

  int field(int offset, String name) {
    final value = info.getUint64(offset, Endian.little);
    if (value == _unwritten64) {
      throw MemoryReadException(
        'K32GetProcessMemoryInfo succeeded but did not write $name',
      );
    }
    return value;
  }

  final workingSet = field(workingSetSizeOffset, 'WorkingSetSize');
  final commit = field(pagefileUsageOffset, 'PagefileUsage');
  final peak = field(peakPagefileUsageOffset, 'PeakPagefileUsage');

  int? fileBacked;
  if (cb >= processMemoryCountersEx2Size) {
    final privateWorkingSet = info.getUint64(
      privateWorkingSetSizeOffset,
      Endian.little,
    );
    if (privateWorkingSet != _unwritten64) {
      if (privateWorkingSet <= workingSet) {
        fileBacked = workingSet - privateWorkingSet;
      }
    }
  }
  return WindowsProcessCounters(
    commitBytes: commit,
    peakCommitBytes: peak,
    fileBackedBytes: fileBacked,
  );
}

/// `ullAvailPhys` out of a `MEMORYSTATUSEX` that `GlobalMemoryStatusEx`
/// filled.
int availablePhysFromMemoryStatus(ByteData status) {
  if (status.lengthInBytes < memoryStatusExSize) {
    throw MemoryReadException(
      'a MEMORYSTATUSEX buffer of ${status.lengthInBytes} bytes is too small',
    );
  }
  return status.getUint64(availPhysOffset, Endian.little);
}

/// Calls `K32GetProcessMemoryInfo` with a size of `cb` on the buffer
/// [readProcessCounters] was given, returning whether it succeeded. A seam so
/// the sentinel and fallback paths run on any host.
typedef ProcessMemoryQuery = bool Function(int cb);

/// Asks [query] for the largest struct first, then for the basic one, both on
/// [buffer] (at least [processMemoryCountersEx2Size] bytes).
///
/// The `_EX2` struct (`cb` 96) needs a Windows 10 or 11 with the 2023 update;
/// if the call refuses it, the basic struct every version fills is asked for
/// instead and `fileBackedBytes` is null. A call that fails on both throws
/// [MemoryReadException] with [lastError]'s code.
WindowsProcessCounters readProcessCounters(
  Uint8List buffer,
  ProcessMemoryQuery query, {
  required int Function() lastError,
}) {
  for (final cb in [processMemoryCountersEx2Size, processMemoryCountersSize]) {
    markUnwritten(buffer);
    // The OS may read `cb` from the struct as well as from the argument.
    ByteData.sublistView(buffer).setUint32(0, cb, Endian.little);
    if (query(cb)) {
      return windowsCountersFromReply(ByteData.sublistView(buffer), cb);
    }
  }
  throw MemoryReadException(
    'K32GetProcessMemoryInfo failed with error ${lastError()}',
  );
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _ProcessMemoryInfoNative =
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32);
typedef _ProcessMemoryInfoDart = int Function(int, Pointer<Uint8>, int);
typedef _GlobalMemoryStatusNative = Int32 Function(Pointer<Uint8>);
typedef _GlobalMemoryStatusDart = int Function(Pointer<Uint8>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

final class _Kernel32 {
  _Kernel32._(
    this.getCurrentProcess,
    this.processMemoryInfo,
    this.globalMemoryStatus,
    this.getLastError,
  );

  factory _Kernel32.open() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    return _Kernel32._(
      _lookup(
        () => kernel32
            .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
              'GetCurrentProcess',
            ),
        'GetCurrentProcess',
      ),
      _lookup(
        () => kernel32
            .lookupFunction<_ProcessMemoryInfoNative, _ProcessMemoryInfoDart>(
              'K32GetProcessMemoryInfo',
            ),
        'K32GetProcessMemoryInfo',
      ),
      _lookup(
        () => kernel32
            .lookupFunction<_GlobalMemoryStatusNative, _GlobalMemoryStatusDart>(
              'GlobalMemoryStatusEx',
            ),
        'GlobalMemoryStatusEx',
      ),
      _lookup(
        () => kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
          'GetLastError',
        ),
        'GetLastError',
      ),
    );
  }

  final _GetCurrentProcessDart getCurrentProcess;
  final _ProcessMemoryInfoDart processMemoryInfo;
  final _GlobalMemoryStatusDart globalMemoryStatus;
  final _GetLastErrorDart getLastError;
}

// Resolved on the first snapshot and kept: a failed resolution is not cached,
// so the next call throws again instead of returning a stale null.
_Kernel32? _kernel32;

/// Reads this process's memory from `kernel32`.
///
/// Runs on Windows, x64 and ARM64; the FFI calls are exercised by the package
/// tests on a `windows-latest` runner and by
/// `flutter_edge_ai/example/integration_test/diagnostics_memory_test.dart`.
/// Throws [MemoryReadException] when a symbol is missing or a call fails; the
/// error code in the message is read by a second FFI call after the failure,
/// so it is a hint, not a guarantee.
MemorySnapshot readWindowsMemorySnapshot() {
  final k = _kernel32 ??= _Kernel32.open();
  final native = calloc<Uint8>(processMemoryCountersEx2Size);
  final status = calloc<Uint8>(memoryStatusExSize);
  try {
    // A pseudo handle: it needs no CloseHandle.
    final self = k.getCurrentProcess();
    final counters = readProcessCounters(
      native.asTypedList(processMemoryCountersEx2Size),
      (cb) => k.processMemoryInfo(self, native, cb) != 0,
      lastError: k.getLastError,
    );

    final statusBytes = status.asTypedList(memoryStatusExSize);
    statusBytes.fillRange(0, memoryStatusExSize, 0);
    ByteData.sublistView(
      statusBytes,
    ).setUint32(0, memoryStatusExSize, Endian.little); // dwLength
    if (k.globalMemoryStatus(status) == 0) {
      throw MemoryReadException(
        'GlobalMemoryStatusEx failed with error ${k.getLastError()}',
      );
    }

    return MemorySnapshot(
      anonymousBytes: counters.commitBytes,
      anonymousPeakBytes: counters.peakCommitBytes,
      fileBackedBytes: counters.fileBackedBytes,
      availableBytes: availablePhysFromMemoryStatus(
        ByteData.sublistView(statusBytes),
      ),
      takenAt: DateTime.now(),
    );
  } finally {
    calloc
      ..free(native)
      ..free(status);
  }
}

T _lookup<T>(T Function() lookup, String symbol) {
  try {
    return lookup();
  } on ArgumentError catch (e) {
    throw MemoryReadException('$symbol is missing from kernel32', cause: e);
  }
}
