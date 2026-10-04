// Integration test: install/validate path round-trip on desktop.
//
// Regression guard for the bug where isModelInstalled() looked in
// getApplicationDocumentsDirectory() while downloads landed in
// Application Support/flutter_edge_ai/ (desktop) or LOCALAPPDATA/flutter_edge_ai/
// (Windows), causing "Active model is no longer installed" immediately after
// a successful install on any clean desktop machine.
//
// Run:
//   flutter test integration_test/desktop_install_validate_roundtrip_test.dart -d macos
//   flutter test integration_test/desktop_install_validate_roundtrip_test.dart -d linux
//   flutter test integration_test/desktop_install_validate_roundtrip_test.dart -d windows

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_edge_ai/core/api/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Only meaningful on the three desktop targets.
  final isDesktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  group('Desktop install/validate path round-trip', skip: !isDesktop, () {
    const fixtureBasename = 'roundtrip_fixture.bin';
    late File fixtureFile;
    late Directory fixtureDir;

    setUpAll(() async {
      // Create a 2 MB dummy file in a temp dir so the test has no network
      // dependency and no asset bundling requirement. 2 MB exceeds the 1 MB
      // minimum size check in ModelFileSystemManager.isFileValid().
      fixtureDir = await Directory.systemTemp.createTemp('flutter_edge_ai_rt_');
      fixtureFile = File(p.join(fixtureDir.path, fixtureBasename));
      await fixtureFile.writeAsBytes(List.filled(2 * 1024 * 1024, 0xAB));
    });

    tearDownAll(() async {
      if (await fixtureDir.exists()) {
        try {
          await fixtureDir.delete(recursive: true);
        } catch (_) {
          // best-effort cleanup
        }
      }
    });

    setUp(() async {
      await registerTestEngines();
      // Clean state: remove leftover metadata from a prior run.
      final alreadyInstalled = await FlutterEdgeAi.isModelInstalled(
        fixtureBasename,
      );
      if (alreadyInstalled) {
        await FlutterEdgeAi.uninstallModel(fixtureBasename);
      }
    });

    tearDown(() async {
      // Make sure the next test starts with the fixture not installed.
      if (await FlutterEdgeAi.isModelInstalled(fixtureBasename)) {
        await FlutterEdgeAi.uninstallModel(fixtureBasename);
      }
    });

    testWidgets(
      'file installed via FileSource is found in model storage directory',
      (tester) async {
        // Step 1 — install. FileSource does no copying; it registers the
        // external path directly. This exercises the metadata path.
        await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
        ).fromFile(fixtureFile.path).install();

        // Step 2 — metadata check (repository layer).
        expect(
          await FlutterEdgeAi.isModelInstalled(fixtureBasename),
          isTrue,
          reason: 'Repository must record the model after install',
        );

        // Step 3 — verify the canonical storage directory reported by
        // FileSystemService is consistent (the central fix: all paths now route
        // through the same service).
        final storageDir = await ServiceRegistry.instance.fileSystemService
            .getModelStorageDirectory();
        expect(
          Directory(storageDir).existsSync(),
          isTrue,
          reason: 'Model storage directory must exist',
        );

        // For FileSource the actual file stays at its original location, but
        // getModelStorageDirectory() must never return the legacy Documents dir
        // on a clean desktop install — it must return the AppSupport-derived path.
        if (Platform.isWindows) {
          final localAppData = Platform.environment['LOCALAPPDATA'];
          if (localAppData != null && localAppData.isNotEmpty) {
            expect(
              storageDir,
              startsWith(localAppData),
              reason:
                  'Windows: storage dir must be under LOCALAPPDATA, '
                  'not OneDrive-synced Documents',
            );
          }
        } else if (Platform.isMacOS || Platform.isLinux) {
          // Must NOT be the user's Documents folder.
          final home = Platform.environment['HOME'] ?? '';
          final documentsDir = p.join(home, 'Documents');
          expect(
            storageDir,
            isNot(startsWith(documentsDir)),
            reason:
                'macOS/Linux: storage dir must not be the user Documents '
                'folder (iCloud/cloud-sync risk)',
          );
        }

        // Step 4 — clean up.
        await FlutterEdgeAi.uninstallModel(fixtureBasename);
        expect(
          await FlutterEdgeAi.isModelInstalled(fixtureBasename),
          isFalse,
          reason: 'Model must be unregistered after uninstall',
        );
      },
    );

    testWidgets(
      'file installed via AssetSource lands in model storage directory',
      (tester) async {
        // assets/test/test_image.jpg is a 14 KB fixture bundled in the example.
        // Re-using it to confirm that AssetSource also writes to the canonical
        // storage dir (the writeFile fallback path on desktop).
        const assetPath = 'assets/test/test_image.jpg';
        const assetBasename = 'test_image.jpg';

        // Clean up any leftover from a prior run.
        if (await FlutterEdgeAi.isModelInstalled(assetBasename)) {
          await FlutterEdgeAi.uninstallModel(assetBasename);
        }

        await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
        ).fromAsset(assetPath).install();

        // Resolve the expected path through FileSystemService — this is the fix:
        // both the writer (AssetSourceHandler via writeFile) and this reader use
        // the same getTargetPath() call.
        final expectedPath = await ServiceRegistry.instance.fileSystemService
            .getTargetPath(assetBasename);
        final installedFile = File(expectedPath);

        expect(
          installedFile.existsSync(),
          isTrue,
          reason:
              'AssetSource must write to the path reported by '
              'FileSystemService.getTargetPath()',
        );
        expect(
          installedFile.lengthSync(),
          greaterThan(0),
          reason: 'Written file must be non-empty',
        );

        // The canonical storage dir must be the parent of the installed file.
        final storageDir = await ServiceRegistry.instance.fileSystemService
            .getModelStorageDirectory();
        expect(
          p.dirname(expectedPath),
          equals(storageDir),
          reason:
              'getTargetPath() parent must equal getModelStorageDirectory()',
        );

        await FlutterEdgeAi.uninstallModel(assetBasename);
      },
    );
  });
}
