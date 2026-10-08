// Device test for flutter_edge_ai_diagnostics: proves the numbers are real on an
// actual Android or iOS process, which host tests cannot do for iOS at all.
//
//   flutter test integration_test/diagnostics_memory_test.dart -d <device-id>
//
// No setUp, on purpose (Rule 6b): anything that can fail sits inside the test
// body, so a failure is reported as a failure.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Off Android and iOS memorySnapshot() throws by design, so these skip there
  // rather than fail.
  final skip = !FlutterEdgeAiDiagnostics.isSupported;

  testWidgets('reports both values on a real device', (tester) async {
    final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
    // ignore: avoid_print
    print('diagnostics snapshot on ${Platform.operatingSystem}: $snapshot');

    expect(snapshot.anonymousBytes, isNotNull);
    expect(snapshot.anonymousBytes, greaterThan(0));
    // fileBackedBytes exists on Android only: the app's own libraries are
    // always resident clean file pages. On iOS it is null by design.
    if (Platform.isAndroid) {
      expect(snapshot.fileBackedBytes, isNotNull);
      expect(snapshot.fileBackedBytes, greaterThan(0));
    } else {
      expect(snapshot.fileBackedBytes, isNull);
    }
    // availableBytes is legitimately null on the iOS simulator (no jetsam
    // limit), so only a real device is held to it.
    if (Platform.isAndroid || !_isIosSimulator) {
      expect(snapshot.availableBytes, isNotNull);
      expect(snapshot.availableBytes, greaterThan(0));
    }
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
