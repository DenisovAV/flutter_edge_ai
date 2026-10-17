// Device test for flutter_edge_ai_diagnostics: proves the numbers are real on an
// actual Android, iOS or macOS process, which host tests cannot do for iOS and
// macOS at all.
//
//   flutter test integration_test/diagnostics_memory_test.dart -d <device-id> --no-uninstall
//
// No setUp, on purpose (Rule 6b): anything that can fail sits inside the test
// body, so a failure is reported as a failure.
import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Off Android, iOS and macOS memorySnapshot() throws by design, so these skip
  // there rather than fail.
  final skip = !FlutterEdgeAiDiagnostics.isSupported;

  testWidgets('reports the supported values on a real device', (tester) async {
    final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
    // ignore: avoid_print
    print('diagnostics snapshot on ${Platform.operatingSystem}: $snapshot');

    expect(snapshot.anonymousBytes, isNotNull);
    expect(snapshot.anonymousBytes, greaterThan(0));
    // Android reports resident clean pages, including mapped framework and
    // library files. The package does not read this value on iOS yet.
    if (Platform.isAndroid) {
      expect(snapshot.fileBackedBytes, isNotNull);
      expect(snapshot.fileBackedBytes, greaterThan(0));
    } else {
      expect(snapshot.fileBackedBytes, isNull);
    }
    // The peak is the kernel's lifetime high-water mark of the footprint, read
    // in the same call, so it is at least the current value. Android keeps no
    // anonymous-only peak.
    if (Platform.isAndroid) {
      expect(snapshot.anonymousPeakBytes, isNull);
    } else {
      expect(snapshot.anonymousPeakBytes, isNotNull);
      expect(
        snapshot.anonymousPeakBytes,
        greaterThanOrEqualTo(snapshot.anonymousBytes!),
      );
    }
    // availableBytes is legitimately null on the iOS simulator (no jetsam
    // limit) and always null on macOS (no per-app limit), so only an Android
    // device or a real iPhone is held to it.
    if (Platform.isMacOS) {
      expect(snapshot.availableBytes, isNull);
    } else if (Platform.isAndroid || !_isIosSimulator) {
      expect(snapshot.availableBytes, isNotNull);
      expect(snapshot.availableBytes, greaterThan(0));
    }
  }, skip: skip);

  testWidgets('gpuMemory is non-null exactly when the process maps kgsl-3d0', (
    tester,
  ) async {
    // ignore: experimental_member_use
    final reading = await FlutterEdgeAiDiagnostics.gpuMemory();
    // ignore: avoid_print
    print('gpuMemory: $reading');
    if (!Platform.isAndroid) {
      expect(reading, isNull);
      return;
    }
    // The oracle does not use the package's parser: /proc/self/maps, and the
    // Pss of the same mappings from smaps, summed by hand.
    final maps = File('/proc/self/maps').readAsStringSync(encoding: latin1);
    expect(reading != null, maps.contains('kgsl-3d0'));
    if (reading == null) return;
    var pssKb = 0;
    var inKgsl = false;
    for (final line in File(
      '/proc/self/smaps',
    ).readAsStringSync(encoding: latin1).split('\n')) {
      if (line.isEmpty) continue;
      final c = line.codeUnitAt(0);
      if ((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
        inKgsl = line.contains('kgsl-3d0');
      } else if (inKgsl && line.startsWith('Pss:')) {
        pssKb += int.parse(line.split(RegExp(r'\s+'))[1]);
      }
    }
    final partsKb =
        (reading.inAnonymousBytes + reading.inFileBackedBytes) ~/ 1024;
    // Shared pages are divided in Pss and counted whole in Shared_Clean, so
    // the parts can only be equal or larger; a GPU mapping is not shared.
    expect(partsKb, greaterThanOrEqualTo(pssKb - 1024));
    expect(partsKb, lessThan(pssKb + 4096));
    expect(reading.outsideSnapshotBytes, isNull);
  }, skip: skip);

  testWidgets('anonymousBytes rises by what the app actually allocates', (
    tester,
  ) async {
    const size = 256 * 1024 * 1024;
    final before =
        (await FlutterEdgeAiDiagnostics.memorySnapshot()).anonymousBytes!;

    // Zeroed pages are not resident until written, so touch every one.
    final block = Uint8List(size)..fillRange(0, size, 1);
    final after =
        (await FlutterEdgeAiDiagnostics.memorySnapshot()).anonymousBytes!;

    // ignore: avoid_print
    print('anonymousBytes delta after writing 256 MiB: ${after - before}');
    expect(block[size - 1], 1); // keep `block` alive past the second read
    expect(after - before, greaterThanOrEqualTo(size * 3 ~/ 4));
  }, skip: skip);
}

/// The executable path is the reliable tell: on iOS 26.5 the app process sees
/// no `SIMULATOR_*` environment variables at all. On the simulator the path is
/// `…/CoreSimulator/Devices/<udid>/…/Runner.app/Runner`; on a device it is
/// under `/private/var/containers/`.
bool get _isIosSimulator =>
    Platform.isIOS &&
    Platform.resolvedExecutable.contains('/CoreSimulator/Devices/');
