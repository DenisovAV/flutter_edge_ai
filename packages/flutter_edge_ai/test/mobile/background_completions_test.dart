// #873: a model download that finished while the app was closed was downloaded
// again. background_downloader stores the final status update of a task that
// finishes while the app is dead and `resumeFromBackground()` replays it once
// per process, popping it as it does. These tests hold what core keeps from
// that replay and when it lets the network install reuse the file.
import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/src/mobile/background_completions.dart';
import 'package:flutter_edge_ai/src/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

const _group = SmartDownloader.downloadGroup;
const _url = 'https://example.invalid/model.litertlm';

DownloadTask _task({
  String taskId = 'model',
  String url = _url,
  String group = _group,
}) => DownloadTask(
  taskId: taskId,
  url: url,
  filename: 'model.litertlm',
  group: group,
  updates: Updates.statusAndProgress,
);

TaskStatusUpdate _complete({
  DownloadTask? task,
  int statusCode = 200,
  Map<String, String>? headers = const {'content-length': '2048'},
}) => TaskStatusUpdate(
  task ?? _task(),
  TaskStatus.complete,
  null,
  null,
  headers,
  statusCode,
);

/// A [BackgroundCompletions] over a broadcast stream, whose `resume` delivers
/// [replay] into it as background_downloader's group callback does.
({
  BackgroundCompletions completions,
  List<bool> listenedAtResume,
  int Function() resumes,
})
_harness(List<TaskUpdate> replay, {Object? resumeError}) {
  final updates = StreamController<TaskUpdate>.broadcast();
  final listenedAtResume = <bool>[];
  var resumes = 0;
  final completions = BackgroundCompletions(
    updates: () => updates.stream,
    resume: () async {
      resumes += 1;
      listenedAtResume.add(updates.hasListener);
      if (resumeError != null) throw resumeError;
      replay.forEach(updates.add);
    },
    group: _group,
  );
  return (
    completions: completions,
    listenedAtResume: listenedAtResume,
    resumes: () => resumes,
  );
}

Future<bool> _inactive(String _) async => false;

void main() {
  group('reconcile', () {
    test('listens before resumeFromBackground() and calls it once', () async {
      final h = _harness([_complete()]);
      await h.completions.reconcile();
      await h.completions.reconcile();
      await h.completions.takeFor('model', _url, isActive: _inactive);
      expect(h.resumes(), 1);
      expect(h.listenedAtResume, [isTrue]);
    });

    test(
      'keeps a replayed completion of core\'s group, with its size',
      () async {
        final h = _harness([_complete()]);
        final completion = await h.completions.takeFor(
          'model',
          _url,
          isActive: _inactive,
        );
        expect(completion, isNotNull);
        expect(completion!.url, _url);
        expect(completion.totalBytes, 2048);
      },
    );

    test('ignores other groups, other statuses and progress', () async {
      final h = _harness([
        _complete(
          task: _task(taskId: 'host', group: 'host_group'),
        ),
        TaskStatusUpdate(_task(taskId: 'failed'), TaskStatus.failed),
        TaskStatusUpdate(_task(taskId: 'paused'), TaskStatus.paused),
        TaskProgressUpdate(_task(taskId: 'progress'), 1.0),
      ]);
      for (final id in ['host', 'failed', 'paused', 'progress']) {
        expect(
          await h.completions.takeFor(id, _url, isActive: _inactive),
          isNull,
          reason: id,
        );
      }
    });

    test(
      'a failing resumeFromBackground() is no evidence, not an error',
      () async {
        final h = _harness([], resumeError: StateError('no plugin'));
        await expectLater(h.completions.reconcile(), completes);
        expect(
          await h.completions.takeFor('model', _url, isActive: _inactive),
          isNull,
        );
      },
    );

    test(
      'an install before core\'s startup call triggers the replay',
      () async {
        final h = _harness([_complete()]);
        // takeFor first, as an install racing the delayed startup reclaim does.
        expect(
          await h.completions.takeFor('model', _url, isActive: _inactive),
          isNotNull,
        );
        // The startup call then only waits.
        await h.completions.reconcile();
        expect(h.resumes(), 1);
      },
    );
  });

  group('takeFor', () {
    test('a live or paused task is left to the attach/resume path', () async {
      final h = _harness([_complete()]);
      expect(
        await h.completions.takeFor('model', _url, isActive: (_) async => true),
        isNull,
      );
    });

    test(
      'a completion of another source under the same name is not reused',
      () async {
        // The task id comes from the path, so an earlier install of another URL
        // under this name leaves a completion with the same id.
        final h = _harness([
          _complete(task: _task(url: 'https://example.invalid/old.litertlm')),
        ]);
        expect(
          await h.completions.takeFor('model', _url, isActive: _inactive),
          isNull,
        );
      },
    );

    test('a refreshed signed link is the same source', () async {
      final h = _harness([
        _complete(task: _task(url: '$_url?X-Amz-Signature=old&expires=1')),
      ]);
      expect(
        await h.completions.takeFor(
          'model',
          '$_url?X-Amz-Signature=new&expires=2',
          isActive: _inactive,
        ),
        isNotNull,
      );
    });

    test('a completion is used once', () async {
      final h = _harness([_complete()]);
      expect(
        await h.completions.takeFor('model', _url, isActive: _inactive),
        isNotNull,
      );
      expect(
        await h.completions.takeFor('model', _url, isActive: _inactive),
        isNull,
      );
    });

    test('a completion for another source is discarded, not kept', () async {
      final h = _harness([
        _complete(task: _task(url: 'https://example.invalid/old.litertlm')),
      ]);
      await h.completions.takeFor('model', _url, isActive: _inactive);
      expect(
        await h.completions.takeFor(
          'model',
          'https://example.invalid/old.litertlm',
          isActive: _inactive,
        ),
        isNull,
      );
    });
  });

  group('through background_downloader\'s own dispatcher', () {
    setUp(() async {
      SmartDownloader.clearConfiguration();
      await FileDownloader().resetUpdates();
    });

    tearDown(() async {
      SmartDownloader.clearConfiguration();
      await FileDownloader().resetUpdates();
    });

    test(
      'a replayed completion reaches the capture via the group fan-out',
      () async {
        // `resume` replays as retrieveLocallyStoredData() does: the stored update
        // goes through processStatusUpdate, i.e. the real group-callback dispatch.
        final completions = BackgroundCompletions(
          updates: SmartDownloader.debugResolveUpdatesStream,
          resume: () async => FileDownloader().downloaderForTesting
              .processStatusUpdate(_complete()),
          group: _group,
        );
        final completion = await completions.takeFor(
          'model',
          _url,
          isActive: _inactive,
        );
        expect(completion?.totalBytes, 2048);
      },
    );

    test('with a host hub configured the capture reads the hub, not a callback '
        'of its own (#445)', () async {
      final hub = StreamController<TaskUpdate>.broadcast();
      addTearDown(hub.close);
      SmartDownloader.configureDownloadUpdatesStream(hub.stream);
      final completions = BackgroundCompletions(
        updates: SmartDownloader.debugResolveUpdatesStream,
        resume: () async => hub.add(_complete()),
        group: _group,
      );
      expect(
        await completions.takeFor('model', _url, isActive: _inactive),
        isNotNull,
      );
      expect(SmartDownloader.debugGroupFanOutIsLive, isFalse);
    });
  });

  group('totalBytesOf', () {
    test('200: X-Linked-Size, then Content-Length, any letter case', () {
      expect(totalBytesOf(200, {'Content-Length': '10'}), 10);
      expect(
        totalBytesOf(200, {'x-linked-size': '99', 'content-length': '10'}),
        99,
      );
      expect(totalBytesOf(200, {'X-LINKED-SIZE': ' 7 '}), 7);
    });

    test('206: the total of Content-Range', () {
      expect(totalBytesOf(206, {'content-range': 'bytes 100-199/2048'}), 2048);
      expect(totalBytesOf(206, {'Content-Range': 'bytes 0-0/*'}), isNull);
      expect(totalBytesOf(206, {'content-length': '100'}), isNull);
    });

    test('nothing usable is null', () {
      expect(totalBytesOf(200, null), isNull);
      expect(totalBytesOf(200, const {}), isNull);
      expect(totalBytesOf(200, {'content-length': 'lots'}), isNull);
      expect(totalBytesOf(200, {'content-length': '-1'}), isNull);
      expect(totalBytesOf(null, {'content-length': '10'}), isNull);
      expect(totalBytesOf(304, {'content-length': '10'}), isNull);
    });
  });
}
