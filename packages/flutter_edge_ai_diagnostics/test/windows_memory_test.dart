import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show FlutterEdgeAiDiagnostics, MemoryReadException;
import 'package:flutter_edge_ai_diagnostics/src/windows/windows_memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _mib = 1024 * 1024;

/// A reply as `K32GetProcessMemoryInfo` leaves the buffer: everything the call
/// did not write still holds the marker.
Uint8List _reply({
  int? workingSet,
  int? pagefileUsage,
  int? peakPagefileUsage,
  int? privateWorkingSet,
}) {
  final buffer = Uint8List(processMemoryCountersEx2Size);
  markUnwritten(buffer);
  final data = ByteData.sublistView(buffer);
  void put(int offset, int? value) {
    if (value != null) data.setUint64(offset, value, Endian.little);
  }

  put(workingSetSizeOffset, workingSet);
  put(pagefileUsageOffset, pagefileUsage);
  put(peakPagefileUsageOffset, peakPagefileUsage);
  put(privateWorkingSetSizeOffset, privateWorkingSet);
  return buffer;
}

WindowsProcessCounters _decode(Uint8List reply, int cb) =>
    windowsCountersFromReply(ByteData.sublistView(reply), cb);

void main() {
  group('PROCESS_MEMORY_COUNTERS layout (64-bit)', () {
    test('the basic struct is two DWORDs and eight SIZE_Ts', () {
      expect(processMemoryCountersSize, 2 * 4 + 8 * 8);
    });

    test('fields sit where psapi.h puts them', () {
      // PeakWorkingSetSize 8, WorkingSetSize 16, four quota fields 24..48,
      // PagefileUsage 56, PeakPagefileUsage 64.
      expect(workingSetSizeOffset, 16);
      expect(pagefileUsageOffset, 56);
      expect(peakPagefileUsageOffset, 64);
      expect(pagefileUsageOffset + 8, peakPagefileUsageOffset);
    });

    test('EX adds PrivateUsage and EX2 adds two ULONGLONGs after it', () {
      const exSize = processMemoryCountersSize + 8; // PrivateUsage at 72
      expect(privateWorkingSetSizeOffset, exSize);
      expect(processMemoryCountersEx2Size, exSize + 2 * 8);
    });

    test(
      'MEMORYSTATUSEX has ullAvailPhys after two DWORDs and ullTotalPhys',
      () {
        expect(availPhysOffset, 2 * 4 + 8);
        expect(memoryStatusExSize, 2 * 4 + 7 * 8);
      },
    );
  });

  group('windowsCountersFromReply', () {
    test('reads commit, its peak and the file-backed part of the working '
        'set', () {
      final counters = _decode(
        _reply(
          workingSet: 400 * _mib,
          pagefileUsage: 500 * _mib,
          peakPagefileUsage: 600 * _mib,
          privateWorkingSet: 300 * _mib,
        ),
        processMemoryCountersEx2Size,
      );
      expect(counters.commitBytes, 500 * _mib);
      expect(counters.peakCommitBytes, 600 * _mib);
      expect(counters.fileBackedBytes, 100 * _mib);
    });

    test('a private working set that is genuinely 0 is a value, not a gap', () {
      final counters = _decode(
        _reply(
          workingSet: 7 * _mib,
          pagefileUsage: 1,
          peakPagefileUsage: 1,
          privateWorkingSet: 0,
        ),
        processMemoryCountersEx2Size,
      );
      expect(counters.fileBackedBytes, 7 * _mib);
    });

    test('PrivateWorkingSetSize left unwritten is a null, not a number made of '
        'the marker', () {
      // The OS accepted cb 96 and filled everything but the field.
      final counters = _decode(
        _reply(
          workingSet: 400 * _mib,
          pagefileUsage: 500 * _mib,
          peakPagefileUsage: 600 * _mib,
        ),
        processMemoryCountersEx2Size,
      );
      expect(counters.fileBackedBytes, isNull);
      expect(counters.commitBytes, 500 * _mib);
    });

    test('the basic struct never reads PrivateWorkingSetSize', () {
      // Even if its bytes held something, a cb of 72 did not ask for them.
      final counters = _decode(
        _reply(
          workingSet: 400 * _mib,
          pagefileUsage: 500 * _mib,
          peakPagefileUsage: 600 * _mib,
          privateWorkingSet: 1,
        ),
        processMemoryCountersSize,
      );
      expect(counters.fileBackedBytes, isNull);
    });

    for (final (name, reply) in [
      (
        'WorkingSetSize',
        _reply(pagefileUsage: 1, peakPagefileUsage: 1, privateWorkingSet: 1),
      ),
      (
        'PagefileUsage',
        _reply(workingSet: 1, peakPagefileUsage: 1, privateWorkingSet: 1),
      ),
      (
        'PeakPagefileUsage',
        _reply(workingSet: 1, pagefileUsage: 1, privateWorkingSet: 1),
      ),
    ]) {
      test('a call that succeeded without writing $name is a failed read', () {
        expect(
          () => _decode(reply, processMemoryCountersEx2Size),
          throwsA(
            isA<MemoryReadException>().having(
              (e) => e.message,
              'message',
              contains(name),
            ),
          ),
        );
      });
    }

    test(
      'a private working set above the working set nulls only fileBackedBytes',
      () {
        final c = _decode(
          _reply(
            workingSet: 100,
            pagefileUsage: 7,
            peakPagefileUsage: 9,
            privateWorkingSet: 101,
          ),
          processMemoryCountersEx2Size,
        );
        expect(c.fileBackedBytes, isNull);
        expect(c.commitBytes, 7);
        expect(c.peakCommitBytes, 9);
      },
    );

    test('a size that is not a PROCESS_MEMORY_COUNTERS size is refused', () {
      expect(() => _decode(_reply(), 80), throwsA(isA<ArgumentError>()));
    });

    test('a buffer smaller than cb is a failed read', () {
      expect(
        () => windowsCountersFromReply(
          ByteData(processMemoryCountersSize),
          processMemoryCountersEx2Size,
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });
  });

  group('readProcessCounters', () {
    /// A query that writes [fields] when asked for a size in [accepts], and
    /// fails otherwise. [asked] records every size it was asked for.
    ProcessMemoryQuery fake(
      Uint8List buffer, {
      required Set<int> accepts,
      required List<int> asked,
      required void Function(ByteData data, int cb) write,
    }) {
      return (cb) {
        asked.add(cb);
        // Whatever it does, the first DWORD is the size it was given.
        expect(ByteData.sublistView(buffer).getUint32(0, Endian.little), cb);
        if (!accepts.contains(cb)) return false;
        write(ByteData.sublistView(buffer), cb);
        return true;
      };
    }

    void writeAll(ByteData d, int cb, {bool privateWorkingSet = true}) {
      d.setUint64(workingSetSizeOffset, 400 * _mib, Endian.little);
      d.setUint64(pagefileUsageOffset, 500 * _mib, Endian.little);
      d.setUint64(peakPagefileUsageOffset, 600 * _mib, Endian.little);
      if (privateWorkingSet && cb >= processMemoryCountersEx2Size) {
        d.setUint64(privateWorkingSetSizeOffset, 300 * _mib, Endian.little);
      }
    }

    test('the extended struct is asked for first and used', () {
      final buffer = Uint8List(processMemoryCountersEx2Size);
      final asked = <int>[];
      final counters = readProcessCounters(
        buffer,
        fake(
          buffer,
          accepts: {processMemoryCountersEx2Size},
          asked: asked,
          write: writeAll,
        ),
        lastError: () => fail('no error to report'),
      );
      expect(asked, [processMemoryCountersEx2Size]);
      expect(counters.fileBackedBytes, 100 * _mib);
    });

    test('an OS that refuses cb 96 falls back to the basic struct, and '
        'fileBackedBytes is null', () {
      final buffer = Uint8List(processMemoryCountersEx2Size);
      final asked = <int>[];
      final counters = readProcessCounters(
        buffer,
        fake(
          buffer,
          accepts: {processMemoryCountersSize},
          asked: asked,
          write: writeAll,
        ),
        lastError: () => fail('the fallback succeeded'),
      );
      expect(asked, [processMemoryCountersEx2Size, processMemoryCountersSize]);
      expect(counters.commitBytes, 500 * _mib);
      expect(counters.peakCommitBytes, 600 * _mib);
      expect(counters.fileBackedBytes, isNull);
    });

    test('a refused cb 96 that scribbled on the buffer leaves nothing for the '
        'fallback to read', () {
      final buffer = Uint8List(processMemoryCountersEx2Size);
      final counters = readProcessCounters(buffer, (cb) {
        if (cb == processMemoryCountersEx2Size) {
          // A failed call that still wrote the extended field.
          ByteData.sublistView(
            buffer,
          ).setUint64(privateWorkingSetSizeOffset, 1, Endian.little);
          return false;
        }
        writeAll(ByteData.sublistView(buffer), cb);
        return true;
      }, lastError: () => fail('the fallback succeeded'));
      expect(counters.fileBackedBytes, isNull);
    });

    test('an OS that accepts cb 96 and leaves PrivateWorkingSetSize unwritten '
        'gives a null, with one call', () {
      final buffer = Uint8List(processMemoryCountersEx2Size);
      final asked = <int>[];
      final counters = readProcessCounters(
        buffer,
        fake(
          buffer,
          accepts: {processMemoryCountersEx2Size},
          asked: asked,
          write: (d, cb) => writeAll(d, cb, privateWorkingSet: false),
        ),
        lastError: () => fail('no error to report'),
      );
      expect(asked, [processMemoryCountersEx2Size]);
      expect(counters.fileBackedBytes, isNull);
      expect(counters.commitBytes, 500 * _mib);
    });

    test('both sizes refused: MemoryReadException with the Windows error', () {
      final buffer = Uint8List(processMemoryCountersEx2Size);
      expect(
        () => readProcessCounters(
          buffer,
          (_) => false,
          lastError: () => 87, // ERROR_INVALID_PARAMETER
        ),
        throwsA(
          isA<MemoryReadException>().having(
            (e) => e.message,
            'message',
            contains('87'),
          ),
        ),
      );
    });
  });

  group('availablePhysFromMemoryStatus', () {
    test('reads ullAvailPhys', () {
      final status = ByteData(memoryStatusExSize)
        ..setUint32(0, memoryStatusExSize, Endian.little)
        ..setUint64(8, 16 * 1024 * _mib, Endian.little) // ullTotalPhys
        ..setUint64(availPhysOffset, 7 * 1024 * _mib, Endian.little);
      expect(availablePhysFromMemoryStatus(status), 7 * 1024 * _mib);
    });

    test('a buffer too small for MEMORYSTATUSEX is a failed read', () {
      expect(
        () => availablePhysFromMemoryStatus(ByteData(availPhysOffset + 8)),
        throwsA(isA<MemoryReadException>()),
      );
    });
  });

  group('on a Windows host', skip: !Platform.isWindows, () {
    test('isSupported is true', () {
      expect(FlutterEdgeAiDiagnostics.isSupported, isTrue);
    });

    test('memorySnapshot reads kernel32: the values Windows reports', () async {
      final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
      // ignore: avoid_print
      print('diagnostics snapshot on Windows: $snapshot');
      expect(snapshot.anonymousBytes, greaterThan(0));
      expect(snapshot.availableBytes, greaterThan(0));
      // The peak of commit is read in the same call, so it is at least commit.
      expect(snapshot.anonymousPeakBytes, isNotNull);
      expect(
        snapshot.anonymousPeakBytes,
        greaterThanOrEqualTo(snapshot.anonymousBytes!),
      );
      // Null only on a Windows that predates the extended struct; the file
      // backed part of any running process (its own DLLs) is above zero.
      if (snapshot.fileBackedBytes != null) {
        expect(snapshot.fileBackedBytes, greaterThan(0));
      }
    });

    test('anonymousBytes is the commit charge: it follows an allocation that '
        'is not touched', () async {
      final before = await FlutterEdgeAiDiagnostics.memorySnapshot();
      final block = calloc<Uint8>(256 * _mib);
      try {
        final during = await FlutterEdgeAiDiagnostics.memorySnapshot();
        expect(
          during.anonymousBytes! - before.anonymousBytes!,
          greaterThan(128 * _mib),
          reason: 'commit counts memory when it is allocated, not touched',
        );
        expect(
          during.anonymousPeakBytes,
          greaterThanOrEqualTo(during.anonymousBytes!),
        );
      } finally {
        calloc.free(block);
      }
    });

    test('PagefileUsage, which anonymousBytes reads, equals PrivateUsage', () {
      // Microsoft documents the two as the same number; the snapshot reads
      // the one every Windows fills. One call returns both, so they are from
      // the same instant.
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getCurrentProcess = kernel32
          .lookupFunction<IntPtr Function(), int Function()>(
            'GetCurrentProcess',
          );
      final info = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
            int Function(int, Pointer<Uint8>, int)
          >('K32GetProcessMemoryInfo');
      const exSize = processMemoryCountersSize + 8;
      final native = calloc<Uint8>(exSize);
      try {
        expect(info(getCurrentProcess(), native, exSize), isNot(0));
        final data = ByteData.sublistView(native.asTypedList(exSize));
        expect(
          data.getUint64(pagefileUsageOffset, Endian.little),
          data.getUint64(processMemoryCountersSize, Endian.little),
        );
      } finally {
        calloc.free(native);
      }
    });

    test('gpuMemory is null, not an error and not a kgsl read', () async {
      // ignore: experimental_member_use
      expect(await FlutterEdgeAiDiagnostics.gpuMemory(), isNull);
    });
  });
}
