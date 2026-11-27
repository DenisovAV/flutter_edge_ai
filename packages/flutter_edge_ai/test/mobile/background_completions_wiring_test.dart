// #873: how core wires the capture of downloads that finished while the app was
// closed. Each test here fails if one connection is undone: the stream the
// capture listens to, the task id it is asked with, the startup reclaim going
// through it (and stopping when the replay failed), and the registry handing
// it to the network handler. What the capture itself keeps is held by
// background_completions_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/handlers/network_source_handler.dart';
import 'package:flutter_edge_ai/src/infrastructure/background_completed_downloads.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_edge_ai/src/mobile/smart_downloader.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://example.invalid/model.litertlm';

TaskStatusUpdate _complete(String taskId, {String url = _url}) =>
    TaskStatusUpdate(
      DownloadTask(
        taskId: taskId,
        url: url,
        filename: 'model.litertlm',
        group: SmartDownloader.downloadGroup,
        updates: Updates.statusAndProgress,
      ),
      TaskStatus.complete,
      null,
      null,
      const {'content-length': '2048'},
      200,
    );

Future<bool> _inactive(String _) async => false;

class _Downloads extends Mock implements DownloadService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String support;

  // Once per file: background_downloader caches each base directory's path
  // for the process, so the paths must not change between tests.
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fe_873_wiring_');
    Directory dir(String name) => Directory('${root.path}/$name')..createSync();
    support = dir('support').path;
    PathProviderPlatform.instance = _Paths(
      documents: dir('documents').path,
      support: support,
      // Not the system temp directory, which holds all of these: a path under
      // it would split as BaseDirectory.temporary.
      temporary: dir('tmp').path,
    );
  });

  tearDownAll(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SmartDownloader.clearConfiguration();
    await FileDownloader().resetUpdates();
    SmartDownloader.debugResetBackgroundCompletions();
  });

  tearDown(() async {
    SmartDownloader.clearConfiguration();
    await FileDownloader().resetUpdates();
    SmartDownloader.debugResetBackgroundCompletions();
    ServiceRegistry.reset();
  });

  group('the stream core captures from', () {
    test('the group fan-out: a replay through background_downloader\'s own '
        'dispatch is kept', () async {
      // As retrieveLocallyStoredData() replays: processStatusUpdate, the real
      // group-callback dispatch.
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => FileDownloader().downloaderForTesting
            .processStatusUpdate(_complete('model')),
      );
      final completion = await SmartDownloader.backgroundCompletions.takeFor(
        'model',
        _url,
        isActive: _inactive,
      );
      expect(completion?.totalBytes, 2048);
    });

    test('a host hub, not a callback of core\'s own (#445)', () async {
      final hub = StreamController<TaskUpdate>.broadcast();
      addTearDown(hub.close);
      SmartDownloader.configureDownloadUpdatesStream(hub.stream);
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => hub.add(_complete('model')),
      );
      expect(
        await SmartDownloader.backgroundCompletions.takeFor(
          'model',
          _url,
          isActive: _inactive,
        ),
        isNotNull,
      );
      expect(SmartDownloader.debugGroupFanOutIsLive, isFalse);
    });

    test('a host hub fed from FileDownloader().updates: two hops later, the '
        'replay is still kept', () async {
      // The host forwards background_downloader's own stream into the hub it
      // configured, so the replay reaches core through two streams.
      final hub = StreamController<TaskUpdate>.broadcast();
      addTearDown(hub.close);
      final forward = FileDownloader().updates.listen(hub.add);
      addTearDown(forward.cancel);
      SmartDownloader.configureDownloadUpdatesStream(hub.stream);
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => FileDownloader().downloaderForTesting
            .processStatusUpdate(_complete('model')),
      );
      expect(
        await SmartDownloader.backgroundCompletions.takeFor(
          'model',
          _url,
          isActive: _inactive,
        ),
        isNotNull,
      );
    });
  });

  group('the task id core asks with', () {
    test('is the one a download to that path is given', () async {
      final target = '$support/model.litertlm';
      final taskId = await SmartDownloader.taskIdFor(target);
      expect(
        taskId,
        computeTaskId(BaseDirectory.applicationSupport, '', 'model.litertlm'),
      );
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => FileDownloader().downloaderForTesting
            .processStatusUpdate(_complete(taskId)),
      );
      final asked = <String>[];
      final completion = await SmartDownloader.debugCompletedWhileAway(
        _url,
        target,
        isActive: (id) async {
          asked.add(id);
          return false;
        },
      );
      expect(completion?.totalBytes, 2048);
      expect(asked, [taskId]);
    });

    test('a completion for another path is not this one', () async {
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async =>
            FileDownloader().downloaderForTesting.processStatusUpdate(
              _complete(await SmartDownloader.taskIdFor('$support/other.task')),
            ),
      );
      expect(
        await SmartDownloader.debugCompletedWhileAway(
          _url,
          '$support/model.litertlm',
          isActive: _inactive,
        ),
        isNull,
      );
    });
  });

  group('the startup reclaim', () {
    test('makes the one replay through the capture, then sweeps', () async {
      var resumes = 0;
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => resumes += 1,
      );
      var swept = false;
      await MobileModelManager().reclaimAfterReplay(() async => swept = true);
      expect(resumes, 1);
      expect(swept, isTrue);
      // An install afterwards reuses that replay rather than making another.
      await SmartDownloader.backgroundCompletions.takeFor(
        'model',
        _url,
        isActive: _inactive,
      );
      expect(resumes, 1);
    });

    test('after an install made the replay, only waits for it', () async {
      var resumes = 0;
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async => resumes += 1,
      );
      await SmartDownloader.backgroundCompletions.takeFor(
        'model',
        _url,
        isActive: _inactive,
      );
      var swept = false;
      await MobileModelManager().reclaimAfterReplay(() async => swept = true);
      expect(resumes, 1);
      expect(swept, isTrue);
    });

    test('a replay that failed: no sweep', () async {
      SmartDownloader.debugResetBackgroundCompletions(
        resume: () async =>
            throw PlatformException(code: 'resume', message: 'stored entry'),
      );
      var swept = false;
      await MobileModelManager().reclaimAfterReplay(() async => swept = true);
      expect(swept, isFalse);
    });
  });

  group('the registry', () {
    NetworkSourceHandler networkHandler() =>
        ServiceRegistry.instance.networkHandler as NetworkSourceHandler;

    test('gives core\'s own downloader the completions', () async {
      ServiceRegistry.reset();
      await ServiceRegistry.initialize();
      expect(
        networkHandler().completedDownloads,
        isA<BackgroundCompletedDownloads>(),
      );
    });

    test('an injected DownloadService gets none', () async {
      ServiceRegistry.reset();
      await ServiceRegistry.initialize(downloadService: _Downloads());
      expect(networkHandler().completedDownloads, isNull);
    });
  });
}

class _Paths extends PathProviderPlatform {
  _Paths({
    required this.documents,
    required this.support,
    required this.temporary,
  });

  final String documents;
  final String support;
  final String temporary;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getApplicationCachePath() async => temporary;

  @override
  Future<String?> getTemporaryPath() async => temporary;

  @override
  Future<String?> getLibraryPath() async => '$support/Library';
}
