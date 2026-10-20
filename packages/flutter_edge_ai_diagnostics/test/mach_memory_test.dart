import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;
import 'package:flutter_edge_ai_diagnostics/src/ios/mach_memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// A zeroed `task_vm_info_data_t` buffer with [physFootprint] written where
/// the kernel puts it.
ByteData _taskVmInfo({required int physFootprint, int lengthInBytes = 512}) {
  return ByteData(lengthInBytes)
    ..setUint64(physFootprintOffset, physFootprint, Endian.host);
}

/// The same buffer with `ledger_phys_footprint_peak` written too.
ByteData _taskVmInfoWithPeak({
  required int physFootprint,
  required int peak,
  int lengthInBytes = 512,
}) {
  return _taskVmInfo(physFootprint: physFootprint, lengthInBytes: lengthInBytes)
    ..setUint64(physFootprintPeakOffset, peak, Endian.host);
}

const _kernSuccess = 0;
const _kernInvalidArgument = 4;

void main() {
  group('task_vm_info layout', () {
    test('phys_footprint follows 17 eight-byte and 2 four-byte fields', () {
      expect(physFootprintOffset, 17 * 8 + 2 * 4);
    });

    test('the rev-1 count ends exactly after phys_footprint', () {
      expect(taskVmInfoRev1Count * 4, physFootprintOffset + 8);
    });
  });

  group('ledger_phys_footprint_peak layout', () {
    test('follows phys_footprint and the two revision 2 address fields', () {
      expect(physFootprintPeakOffset, physFootprintOffset + 8 + 2 * 8);
    });

    test('the peak count ends exactly after the field', () {
      expect(taskVmInfoPeakCount * 4, physFootprintPeakOffset + 8);
      expect(taskVmInfoPeakCount, greaterThan(taskVmInfoRev1Count));
    });
  });

  group('physFootprintPeakFromTaskInfoReply', () {
    test('reads the peak when the reply contains it', () {
      final info = _taskVmInfoWithPeak(physFootprint: 100, peak: 900);
      expect(
        physFootprintPeakFromTaskInfoReply(
          _kernSuccess,
          info,
          taskVmInfoPeakCount,
        ),
        900,
      );
    });

    test('does not mistake phys_footprint for the peak', () {
      final info = _taskVmInfoWithPeak(physFootprint: 100, peak: 900);
      expect(physFootprintFromTaskInfoReply(_kernSuccess, info, 128), 100);
    });

    test('a reply that stops before the field gives null, not a failure', () {
      final info = _taskVmInfoWithPeak(physFootprint: 100, peak: 900);
      expect(
        physFootprintPeakFromTaskInfoReply(
          _kernSuccess,
          info,
          taskVmInfoPeakCount - 1,
        ),
        isNull,
      );
    });

    test('a buffer too small to hold the field gives null', () {
      final info = ByteData(physFootprintPeakOffset + 4);
      expect(
        physFootprintPeakFromTaskInfoReply(_kernSuccess, info, 128),
        isNull,
      );
    });

    test('a failed task_info call throws instead of returning null', () {
      final info = _taskVmInfoWithPeak(physFootprint: 100, peak: 900);
      expect(
        () =>
            physFootprintPeakFromTaskInfoReply(_kernInvalidArgument, info, 128),
        throwsA(isA<MemoryReadException>()),
      );
    });
  });

  group('physFootprintFromTaskInfoReply', () {
    test('reads phys_footprint when the reply includes revision 1', () {
      const footprint = 1234567890123;
      final info = _taskVmInfo(physFootprint: footprint);
      expect(
        physFootprintFromTaskInfoReply(_kernSuccess, info, taskVmInfoRev1Count),
        footprint,
      );
    });

    test('reads it from a newer, longer reply', () {
      final info = _taskVmInfo(physFootprint: 42);
      expect(physFootprintFromTaskInfoReply(_kernSuccess, info, 128), 42);
    });

    test('a failed task_info call throws instead of returning null', () {
      final info = _taskVmInfo(physFootprint: 42);
      expect(
        () => physFootprintFromTaskInfoReply(_kernInvalidArgument, info, 128),
        throwsA(
          isA<MemoryReadException>().having(
            (e) => e.message,
            'message',
            contains('kern_return_t $_kernInvalidArgument'),
          ),
        ),
      );
    });

    test('a reply shorter than revision 1 is a failed read', () {
      final info = _taskVmInfo(physFootprint: 42);
      expect(
        () => physFootprintFromTaskInfoReply(
          _kernSuccess,
          info,
          taskVmInfoRev1Count - 1,
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('a buffer that cannot hold the field is a failed read', () {
      final info = ByteData(physFootprintOffset + 4);
      expect(
        () => physFootprintFromTaskInfoReply(_kernSuccess, info, 128),
        throwsA(isA<MemoryReadException>()),
      );
    });
  });

  group('availableBytesFromOsProc', () {
    test('passes a real headroom through', () {
      expect(availableBytesFromOsProc(3 * 1024 * 1024 * 1024), 3 << 30);
    });

    test('maps 0 to null: no limit and limit exceeded look the same', () {
      expect(availableBytesFromOsProc(0), isNull);
    });
  });
}
