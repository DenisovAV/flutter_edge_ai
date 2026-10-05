import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../memory_read_exception.dart';
import '../memory_snapshot.dart';

/// `TASK_VM_INFO`, the `task_info` flavor that returns `task_vm_info_data_t`
/// (`<mach/task_info.h>`).
const int taskVmInfoFlavor = 22;

/// Byte offset of `phys_footprint` in `task_vm_info_data_t`: seventeen
/// 8-byte fields and two 4-byte ones precede it (17 * 8 + 2 * 4 = 144). It
/// arrived with revision 1 of the struct.
const int physFootprintOffset = 144;

/// `TASK_VM_INFO_REV1_COUNT`, in `natural_t` (4-byte) units: the smallest
/// reply that contains `phys_footprint`. A kernel that fills less has not
/// written the field.
const int taskVmInfoRev1Count = 38;

/// Room for later revisions of the struct. The kernel writes what it has and
/// reports how much through the count, so a larger buffer is safe.
const int _bufferCountNatural = 128;

/// `phys_footprint` out of a `task_info(TASK_VM_INFO)` reply.
///
/// [kernReturn] is the call's `kern_return_t`; [returnedCount] is the count
/// the kernel wrote back, in `natural_t` units.
///
/// Throws [MemoryReadException] when the call failed or the reply is too
/// short to contain `phys_footprint`. Every iOS version flutter_gemma supports
/// returns revision 1 or later, so a short reply is a failed read, not a
/// missing feature.
int physFootprintFromTaskInfoReply(
  int kernReturn,
  ByteData info,
  int returnedCount,
) {
  if (kernReturn != 0) {
    throw MemoryReadException(
      'task_info(TASK_VM_INFO) failed with kern_return_t $kernReturn',
    );
  }
  if (returnedCount < taskVmInfoRev1Count) {
    throw MemoryReadException(
      'task_info(TASK_VM_INFO) returned $returnedCount natural_t, fewer than '
      'the $taskVmInfoRev1Count that contain phys_footprint',
    );
  }
  if (info.lengthInBytes < physFootprintOffset + 8) {
    throw MemoryReadException(
      'task_vm_info buffer of ${info.lengthInBytes} bytes cannot hold '
      'phys_footprint',
    );
  }
  return info.getUint64(physFootprintOffset, Endian.host);
}

/// `os_proc_available_memory()` mapped to the snapshot's contract: 0 means
/// either "no limit applies" or "limit already exceeded", which cannot be
/// told apart, so it becomes null.
int? availableBytesFromOsProc(int raw) => raw == 0 ? null : raw;

typedef _TaskInfoNative =
    Int32 Function(Uint32, Uint32, Pointer<Int32>, Pointer<Uint32>);
typedef _TaskInfoDart = int Function(int, int, Pointer<Int32>, Pointer<Uint32>);
typedef _OsProcAvailableNative = Size Function();
typedef _OsProcAvailableDart = int Function();

/// Reads both values from the Mach kernel and libsystem.
///
/// Only runs on iOS; the FFI calls are exercised by
/// `flutter_gemma/example/integration_test/diagnostics_memory_test.dart`.
/// Throws [MemoryReadException] when a symbol is missing or a call fails.
MemorySnapshot readMachMemorySnapshot() {
  final process = DynamicLibrary.process();
  return MemorySnapshot(
    anonymousBytes: _readPhysFootprint(process),
    availableBytes: _readAvailable(process),
    takenAt: DateTime.now(),
  );
}

int _readPhysFootprint(DynamicLibrary process) {
  // `mach_task_self()` is a macro over this global.
  final taskSelf = _lookup(
    () => process.lookup<Uint32>('mach_task_self_').value,
    'mach_task_self_',
  );
  final taskInfo = _lookup(
    () => process.lookupFunction<_TaskInfoNative, _TaskInfoDart>('task_info'),
    'task_info',
  );

  final info = calloc<Int32>(_bufferCountNatural);
  final count = calloc<Uint32>()..value = _bufferCountNatural;
  try {
    final kr = taskInfo(taskSelf, taskVmInfoFlavor, info, count);
    final bytes = info.cast<Uint8>().asTypedList(_bufferCountNatural * 4);
    return physFootprintFromTaskInfoReply(
      kr,
      ByteData.sublistView(bytes),
      count.value,
    );
  } finally {
    calloc
      ..free(info)
      ..free(count);
  }
}

int? _readAvailable(DynamicLibrary process) {
  // Present since iOS 13 and flutter_gemma's floor is iOS 15, so a missing
  // symbol is a failed read, not a gap to report as null.
  final available = _lookup(
    () => process.lookupFunction<_OsProcAvailableNative, _OsProcAvailableDart>(
      'os_proc_available_memory',
    ),
    'os_proc_available_memory',
  );
  return availableBytesFromOsProc(available());
}

T _lookup<T>(T Function() lookup, String symbol) {
  try {
    return lookup();
  } on ArgumentError catch (e) {
    throw MemoryReadException('$symbol is missing from the process', cause: e);
  }
}
