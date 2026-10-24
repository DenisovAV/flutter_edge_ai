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

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

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

  testWidgets('gpuMemory matches an independent sum of the kgsl-3d0 mappings', (
    tester,
  ) async {
    if (!Platform.isAndroid) {
      // ignore: experimental_member_use
      expect(await FlutterEdgeAiDiagnostics.gpuMemory(), isNull);
      return;
    }
    // Before any model: null exactly when the device has no GPU node (a Mali
    // phone), a reading otherwise (zeros if nothing is mapped yet). The node is
    // tested with existsSync: typeSync says notFound for it from an app.
    // ignore: experimental_member_use
    final early = await FlutterEdgeAiDiagnostics.gpuMemory();
    final mapped = File(
      '/proc/self/maps',
    ).readAsStringSync(encoding: latin1).contains('kgsl-3d0');
    expect(early != null, File('/dev/kgsl-3d0').existsSync() || mapped);

    // A model on the GPU first, so the mapping is hundreds of MiB and a parser
    // that drops a component falls far outside the bound. FunctionGemma 270M,
    // staged as in litertlm_functiongemma_gpu_activation_test.dart.
    await registerTestEngines();
    final path = await stagedModelPath('functiongemma-270M-it.litertlm');
    expect(path, isNotNull, reason: 'stage functiongemma-270M-it.litertlm');
    await FlutterEdgeAi.installModel(
      modelType: ModelType.functionGemma,
      fileType: ModelFileType.litertlm,
    ).fromFile(path!).install();
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
      activationDataType: ActivationDataType.float32,
    );
    try {
      expect(model.activeBackend, PreferredBackend.gpu);
      // ignore: experimental_member_use
      final reading = await FlutterEdgeAiDiagnostics.gpuMemory();
      // ignore: avoid_print
      print('gpuMemory: $reading');

      // The oracle does not use the package's parser: /proc/self/maps decides
      // whether there is a mapping, and smaps is summed by hand per field.
      final maps = File('/proc/self/maps').readAsStringSync(encoding: latin1);
      expect(reading != null, maps.contains('kgsl-3d0'));
      if (reading == null) return;
      var dirtyKb = 0;
      var cleanKb = 0;
      var inKgsl = false;
      for (final line in File(
        '/proc/self/smaps',
      ).readAsStringSync(encoding: latin1).split('\n')) {
        if (line.isEmpty) continue;
        final c = line.codeUnitAt(0);
        if ((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
          inKgsl = line.contains('kgsl-3d0');
        } else if (inKgsl) {
          final kb = int.tryParse(
            line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '',
          );
          if (line.startsWith('Private_Dirty:')) dirtyKb += kb!;
          if (line.startsWith('Private_Clean:') ||
              line.startsWith('Shared_Clean:')) {
            cleanKb += kb!;
          }
        }
      }
      // Two reads a moment apart with the model idle: within 1% and 64 KiB.
      void near(int bytes, int expectedKb, String what) {
        final slack = expectedKb * 1024 ~/ 100 + 64 * 1024;
        expect(
          (bytes - expectedKb * 1024).abs(),
          lessThanOrEqualTo(slack),
          reason: '$what: $bytes B vs $expectedKb kB',
        );
      }

      near(reading.inAnonymousBytes, dirtyKb, 'inAnonymousBytes');
      near(reading.inFileBackedBytes, cleanKb, 'inFileBackedBytes');
      // A model on the GPU maps hundreds of MiB: a dropped component fails.
      expect(
        reading.inAnonymousBytes + reading.inFileBackedBytes,
        greaterThan(100 * 1024 * 1024),
      );
      expect(reading.outsideSnapshotBytes, isNull);
    } finally {
      await model.close();
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
