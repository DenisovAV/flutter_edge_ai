// Device test for `MemorySnapshot.anonymousPeakBytes` on iOS and macOS, in a
// file of its own on purpose: the first test needs a clean process. A 256 MiB
// block allocated after another test's block was collected can reuse the pages
// it left, and then neither the footprint nor the peak moves (iOS 26.5
// simulator: footprint 381160328 -> 381389704 when the whole of
// diagnostics_memory_test.dart ran, 114199240 -> 382929800 alone).
//
//   flutter test integration_test/diagnostics_peak_test.dart -d <device-id> --no-uninstall
//
// What would pass for the wrong field, and what this does about it:
// - `max_address` (offset 160) is a virtual address, far above any footprint,
//   so a lower bound alone cannot tell it from the peak; the first test also
//   bounds the peak from above.
// - `phys_footprint` itself (offset 144) is the footprint, not its high-water
//   mark; the second test releases memory and requires the peak to stay.
//
// No setUp, on purpose (Rule 6b): anything that can fail sits inside the test
// body, so a failure is reported as a failure.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _size = 256 * 1024 * 1024;

/// `mmap`'s PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON (Darwin values) and
/// the MAP_FAILED address.
const _protReadWrite = 3;
const _mapPrivateAnon = 0x0002 | 0x1000;
const _mapFailed = -1;

typedef _MmapNative =
    Pointer<Void> Function(Pointer<Void>, IntPtr, Int32, Int32, Int32, Int64);
typedef _Mmap = Pointer<Void> Function(Pointer<Void>, int, int, int, int, int);
typedef _MunmapNative = Int32 Function(Pointer<Void>, IntPtr);
typedef _Munmap = int Function(Pointer<Void>, int);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The peak is read from `task_info`, so only on Apple platforms.
  final skip = !(Platform.isIOS || Platform.isMacOS);

  // Keep this one first: it is the only test that needs a clean process.
  testWidgets('the peak follows the first large allocation up', (tester) async {
    final before = await FlutterEdgeAiDiagnostics.memorySnapshot();

    // Zeroed pages are not resident until written, so touch every one.
    final block = Uint8List(_size)..fillRange(0, _size, 1);
    final after = await FlutterEdgeAiDiagnostics.memorySnapshot();

    // ignore: avoid_print
    print(
      'peak before ${before.anonymousPeakBytes}, after '
      '${after.anonymousPeakBytes}; footprint before ${before.anonymousBytes}, '
      'after ${after.anonymousBytes}',
    );
    expect(block[_size - 1], 1); // keep `block` alive past the second read
    expect(before.anonymousPeakBytes, isNotNull);
    expect(after.anonymousPeakBytes, isNotNull);
    final peak = after.anonymousPeakBytes!;
    final footprint = after.anonymousBytes!;

    // The footprint rose by most of the block, and the peak followed it.
    expect(
      footprint,
      greaterThanOrEqualTo(before.anonymousBytes! + _size * 3 ~/ 4),
    );
    expect(peak, greaterThanOrEqualTo(before.anonymousBytes! + _size * 3 ~/ 4));
    expect(peak, greaterThanOrEqualTo(footprint));
    expect(peak, greaterThanOrEqualTo(before.anonymousPeakBytes!));
    // And it is a footprint high-water mark, not an address: a clean start
    // leaves no room for a peak far above the footprint it is the peak of.
    expect(peak, lessThanOrEqualTo(footprint + 64 * 1024 * 1024));
  }, skip: skip);

  testWidgets('the peak stays after the memory is released', (tester) async {
    final libc = DynamicLibrary.process();
    final mmap = libc.lookupFunction<_MmapNative, _Mmap>('mmap');
    final munmap = libc.lookupFunction<_MunmapNative, _Munmap>('munmap');

    final before = await FlutterEdgeAiDiagnostics.memorySnapshot();
    final block = mmap(nullptr, _size, _protReadWrite, _mapPrivateAnon, -1, 0);
    expect(block.address, isNot(_mapFailed), reason: 'mmap failed');
    final bytes = block.cast<Uint8>().asTypedList(_size);
    for (var i = 0; i < _size; i += 4096) {
      bytes[i] = 1;
    }
    final during = await FlutterEdgeAiDiagnostics.memorySnapshot();

    // `munmap`, not `free`: the pages go back at once, where an allocator may
    // keep them and leave the footprint where it was.
    expect(munmap(block, _size), 0);
    final after = await FlutterEdgeAiDiagnostics.memorySnapshot();

    // ignore: avoid_print
    print(
      'footprint before ${before.anonymousBytes}, during '
      '${during.anonymousBytes}, after ${after.anonymousBytes}; peak '
      'before ${before.anonymousPeakBytes}, during ${during.anonymousPeakBytes}'
      ', after ${after.anonymousPeakBytes}',
    );
    expect(
      during.anonymousBytes! - before.anonymousBytes!,
      greaterThanOrEqualTo(_size * 3 ~/ 4),
    );
    // Released: the footprint fell by most of the block.
    expect(
      after.anonymousBytes!,
      lessThanOrEqualTo(during.anonymousBytes! - _size ~/ 2),
    );
    // The peak is a high-water mark: it did not fall with the footprint.
    expect(
      after.anonymousPeakBytes!,
      greaterThanOrEqualTo(during.anonymousBytes!),
    );
    expect(
      after.anonymousPeakBytes!,
      greaterThan(after.anonymousBytes! + _size ~/ 2),
    );
  }, skip: skip);
}
