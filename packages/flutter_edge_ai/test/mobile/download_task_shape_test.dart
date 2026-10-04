// The ENQUEUE end of #445.
//
// Every other test in this directory watches the listen end — that updates
// reach us and not the host. None of them could see the other half: mutation
// testing showed that changing the enqueued task's `group`, or reverting
// `priority` to 10, or dropping progress updates, left the entire 636-test
// suite green.
//
// The group is the worst of those. `registerCallbacks(group:)` and the task's
// `group:` are two ends of one wire; if they drift, the task lands in a group
// nobody is registered for, background_downloader logs a warning nobody reads,
// and the download hangs forever. Both ends are pinned here to the SAME
// constant, which is what makes this a drift test rather than a tautology.
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask build({String? token, bool allowPause = true}) =>
    buildModelDownloadTask(
      taskId: 'abc',
      url: 'https://example.invalid/model.bin',
      token: token,
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'models',
      filename: 'model.bin',
      allowPause: allowPause,
    );

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the task is enqueued into the group we register for', () {
    expect(
      build().group,
      SmartDownloader.downloadGroup,
      reason:
          'a drift between this and registerCallbacks(group:) means every '
          'update goes to a group nobody listens on, and the download hangs '
          'with only a log line from background_downloader',
    );
  });

  test('progress updates are requested, not just status', () {
    expect(
      build().updates,
      Updates.statusAndProgress,
      reason:
          'with status only, providesProgressUpdates is false and the download '
          'sits at 0% for its whole life while working perfectly',
    );
  });

  test('package-level retries stay off', () {
    expect(
      build().retries,
      0,
      reason:
          'retries are handled here with HTTP-aware logic; package retries '
          'would race that loop, and the reattach path assumes retries: 0',
    );
  });

  test('allowPause is passed through, not assumed', () {
    // HuggingFace serves weak ETags, so resume is unreliable there and the
    // caller decides. Hardcoding true reintroduces the silent-restart failure.
    expect(build(allowPause: false).allowPause, isFalse);
    expect(build(allowPause: true).allowPause, isTrue);
  });

  test('the task carries the platform priority, not a hardcoded one', () {
    // The host here is not Android, so this pins the non-Android arm end to
    // end. Both arms of the decision are covered by priorityForPlatform below;
    // this asserts the task actually uses it.
    expect(build().priority, SmartDownloader.downloadPriority);
    expect(build().priority, 0);
  });

  group('priorityForPlatform', () {
    test('iOS and desktop get the highest', () {
      expect(
        priorityForPlatform(isAndroid: false),
        0,
        reason:
            'iOS maps priority onto URLSession as 1 - p/10, so the old 10 meant '
            '0.0 — below URLSessionTask.lowPriority',
      );
    });

    test('Android must not go below 5', () {
      expect(
        priorityForPlatform(isAndroid: true),
        isNot(lessThan(5)),
        reason:
            'below 5 makes the Android job expedited, and an expedited request '
            'cannot carry the 1s delay background_downloader needs to '
            're-enqueue after WorkManager 9-minute cap — the build throws, the '
            'throw is swallowed, and the download stops at 9 minutes silently',
      );
    });
  });

  test('the auth header is present only when a token is given', () {
    expect(build(token: 't').headers['Authorization'], 'Bearer t');
    expect(build().headers.containsKey('Authorization'), isFalse);
    // Cache headers are unconditional — they work around CDN ETag behaviour.
    expect(build().headers['Cache-Control'], 'no-cache, no-store');
  });

  group('percentFromProgress', () {
    test('negative values are state sentinels, not progress', () {
      // -1 failed, -2 canceled, -3 notFound, -4 waiting to retry, -5 paused.
      for (final sentinel in [-1.0, -2.0, -3.0, -4.0, -5.0]) {
        expect(
          percentFromProgress(sentinel),
          isNull,
          reason:
              'clamping $sentinel to 0 made the bar snap to 0% at every '
              '9-minute slice of a multi-gigabyte download',
        );
      }
    });

    test('real progress becomes a bounded percentage', () {
      expect(percentFromProgress(0), 0);
      expect(percentFromProgress(0.42), 42);
      expect(percentFromProgress(1), 100);
      expect(percentFromProgress(1.5), 100);
    });
  });

  group('shouldRearmWatchdog', () {
    // The blanket _cancelResumeWatchdog that runs before every status disarms
    // the only safety net, so a non-final status carrying no progress has to
    // put it back — or the download hangs unbounded with no error.
    test('paused always re-arms', () {
      expect(shouldRearmWatchdog(TaskStatus.paused, sawPause: false), isTrue);
      expect(shouldRearmWatchdog(TaskStatus.paused, sawPause: true), isTrue);
    });

    test('a FIRST enqueue does not re-arm', () {
      expect(
        shouldRearmWatchdog(TaskStatus.enqueued, sawPause: false),
        isFalse,
        reason:
            'arming here puts a 90-second deadline on every download before it '
            'has started — and the watchdog cancels the task and deletes its '
            'resume data, so a phone in a tunnel loses a multi-gigabyte partial',
      );
    });

    test('an enqueue AFTER a pause re-arms', () {
      expect(
        shouldRearmWatchdog(TaskStatus.enqueued, sawPause: true),
        isTrue,
        reason:
            'this is the resume-driven re-enqueue; if the platform then defers '
            'it, nothing else will ever fire',
      );
    });

    test('final and progress-carrying states do not re-arm', () {
      for (final s in [
        TaskStatus.complete,
        TaskStatus.failed,
        TaskStatus.canceled,
        TaskStatus.notFound,
        TaskStatus.running,
      ]) {
        expect(
          shouldRearmWatchdog(s, sawPause: true),
          isFalse,
          reason: '$s must not arm a resume watchdog',
        );
      }
    });

    test('every TaskStatus is handled', () {
      // A new status added upstream must not silently fall through.
      for (final s in TaskStatus.values) {
        expect(() => shouldRearmWatchdog(s, sawPause: false), returnsNormally);
      }
    });
  });
}
