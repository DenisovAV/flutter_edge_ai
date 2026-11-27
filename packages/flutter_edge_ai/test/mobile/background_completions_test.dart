// #873: a model download that finished while the app was closed was downloaded
// again. background_downloader stores the final status update of a task that
// finishes while the app is dead and `resumeFromBackground()` replays it once
// per process, popping it as it does. These tests hold what core keeps from
// that replay and when it lets the network install reuse the file. How core
// wires it in (the stream, the task id, the startup reclaim, the registry) is
// held by background_completions_wiring_test.dart.
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
  int? statusCode = 200,
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
/// [replay] into it as background_downloader's group callback does — after
/// [resumeGate] completes, when one is given.
({
  BackgroundCompletions completions,
  List<bool> listenedAtResume,
  int Function() resumes,
})
_harness(
  List<TaskUpdate> replay, {
  Object? resumeError,
  Future<void>? resumeGate,
  Duration waitLimit = const Duration(seconds: 10),
}) {
  final updates = StreamController<TaskUpdate>.broadcast();
  final listenedAtResume = <bool>[];
  var resumes = 0;
  final completions = BackgroundCompletions(
    updates: () => updates.stream,
    resume: () async {
      resumes += 1;
      listenedAtResume.add(updates.hasListener);
      if (resumeGate != null) await resumeGate;
      if (resumeError != null) throw resumeError;
      replay.forEach(updates.add);
    },
    group: _group,
    waitLimit: waitLimit,
  );
  return (
    completions: completions,
    listenedAtResume: listenedAtResume,
    resumes: () => resumes,
  );
}

Future<bool> _inactive(String _) async => false;

/// The lines [body] prints.
Future<List<String>> _printed(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  group('reconcile', () {
    test('listens before resumeFromBackground() and calls it once', () async {
      final h = _harness([_complete()]);
      expect(await h.completions.reconcile(), isTrue);
      expect(await h.completions.reconcile(), isTrue);
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
        expect(completion.statedBy, 'Content-Length');
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

    test('keeps only a 200 or 206 that stated the size', () async {
      final h = _harness([
        // trackTasks(markDownloadedComplete: true): a tracked file that merely
        // exists, reported complete with no response at all.
        _complete(
          task: _task(taskId: 'tracked'),
          statusCode: null,
          headers: null,
        ),
        // Config.skipExistingFiles.
        _complete(task: _task(taskId: 'skipped'), statusCode: 304),
        _complete(
          task: _task(taskId: 'no size'),
          headers: const {},
        ),
        _complete(
          task: _task(taskId: 'zero'),
          headers: const {'content-length': '0'},
        ),
        _complete(
          task: _task(taskId: 'resumed'),
          statusCode: 206,
          headers: const {'content-range': 'bytes 1024-2047/2048'},
        ),
      ]);
      for (final id in ['tracked', 'skipped', 'no size', 'zero']) {
        expect(
          await h.completions.takeFor(id, _url, isActive: _inactive),
          isNull,
          reason: id,
        );
      }
      final resumed = await h.completions.takeFor(
        'resumed',
        _url,
        isActive: _inactive,
      );
      expect(resumed?.totalBytes, 2048);
      expect(resumed?.statedBy, 'Content-Range');
    });

    test('a failing resumeFromBackground() reports false, is no evidence, and '
        'is said in release builds', () async {
      final h = _harness([_complete()], resumeError: StateError('no plugin'));
      late bool replayed;
      final lines = await _printed(
        () async => replayed = await h.completions.reconcile(),
      );
      expect(replayed, isFalse);
      expect(lines.single, startsWith('[flutter_edge_ai] WARNING: '));
      expect(lines.single, contains('no plugin'));
      expect(
        await h.completions.takeFor('model', _url, isActive: _inactive),
        isNull,
      );
      expect(h.resumes(), 1);
    });

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
        expect(await h.completions.reconcile(), isTrue);
        expect(h.resumes(), 1);
      },
    );
  });

  group('takeFor', () {
    test('a live or paused task is left to the attach/resume path, and the '
        'completion is used up all the same', () async {
      final h = _harness([_complete()]);
      expect(
        await h.completions.takeFor('model', _url, isActive: (_) async => true),
        isNull,
      );
      expect(
        await h.completions.takeFor('model', _url, isActive: _inactive),
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

    test('another file told apart only by the query is not reused', () async {
      const drive = 'https://drive.example.invalid/uc';
      final h = _harness([
        _complete(task: _task(url: '$drive?id=A&export=download')),
      ]);
      expect(
        await h.completions.takeFor(
          'model',
          '$drive?id=B&export=download',
          isActive: _inactive,
        ),
        isNull,
      );
    });

    test('the same query in another order is the same file', () async {
      const drive = 'https://drive.example.invalid/uc';
      final h = _harness([
        _complete(task: _task(url: '$drive?id=A&export=download')),
      ]);
      expect(
        await h.completions.takeFor(
          'model',
          '$drive?export=download&id=A',
          isActive: _inactive,
        ),
        isNotNull,
      );
    });

    test('a refreshed signed link is the same source', () async {
      final h = _harness([
        _complete(
          task: _task(
            url: '$_url?X-Amz-Signature=old&X-Amz-Date=1&Expires=1&rev=main',
          ),
        ),
      ]);
      expect(
        await h.completions.takeFor(
          'model',
          '$_url?rev=main&X-Amz-Signature=new&X-Amz-Date=2&Expires=2',
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

  group('the wait is bounded', () {
    test('a replay that does not answer is no evidence, and says so; the '
        'replay itself is not given up', () async {
      final gate = Completer<void>();
      final h = _harness(
        [_complete()],
        resumeGate: gate.future,
        waitLimit: const Duration(milliseconds: 20),
      );
      BackgroundCompletion? completion;
      final lines = await _printed(
        () async => completion = await h.completions.takeFor(
          'model',
          _url,
          isActive: _inactive,
        ),
      );
      expect(completion, isNull);
      expect(lines.single, startsWith('[flutter_edge_ai] WARNING: '));

      // The startup reclaim still waits for the real outcome, and the
      // completion the late replay delivers is still there to take.
      var reconciled = false;
      unawaited(h.completions.reconcile().then((_) => reconciled = true));
      await pumpEventQueue();
      expect(reconciled, isFalse);
      gate.complete();
      expect(await h.completions.reconcile(), isTrue);
      expect(
        await h.completions.takeFor('model', _url, isActive: _inactive),
        isNotNull,
      );
      expect(h.resumes(), 1);
    });

    test('a task lookup that does not answer is no evidence', () async {
      final h = _harness([
        _complete(),
      ], waitLimit: const Duration(milliseconds: 20));
      BackgroundCompletion? completion;
      final lines = await _printed(
        () async => completion = await h.completions.takeFor(
          'model',
          _url,
          isActive: (_) => Completer<bool>().future,
        ),
      );
      expect(completion, isNull);
      expect(lines.single, startsWith('[flutter_edge_ai] WARNING: '));
    });
  });

  group('statedTotalOf', () {
    test('200: X-Linked-Size, then Content-Length, any letter case', () {
      expect(statedTotalOf(200, {'Content-Length': '10'}), (
        bytes: 10,
        header: 'Content-Length',
      ));
      expect(
        statedTotalOf(200, {'x-linked-size': '99', 'content-length': '10'}),
        (bytes: 99, header: 'X-Linked-Size'),
      );
      expect(statedTotalOf(200, {'X-LINKED-SIZE': ' 7 '})?.bytes, 7);
    });

    test('206: the total of Content-Range', () {
      expect(statedTotalOf(206, {'content-range': 'bytes 100-199/2048'}), (
        bytes: 2048,
        header: 'Content-Range',
      ));
      expect(statedTotalOf(206, {'Content-Range': 'bytes 0-0/*'}), isNull);
      expect(statedTotalOf(206, {'content-length': '100'}), isNull);
    });

    test('nothing usable is null', () {
      expect(statedTotalOf(200, null), isNull);
      expect(statedTotalOf(200, const {}), isNull);
      expect(statedTotalOf(200, {'content-length': 'lots'}), isNull);
      expect(statedTotalOf(200, {'content-length': '-1'}), isNull);
      expect(statedTotalOf(200, {'content-length': '0'}), isNull);
      expect(statedTotalOf(206, {'content-range': 'bytes */0'}), isNull);
      expect(statedTotalOf(null, {'content-length': '10'}), isNull);
      expect(statedTotalOf(304, {'content-length': '10'}), isNull);
    });
  });
}
