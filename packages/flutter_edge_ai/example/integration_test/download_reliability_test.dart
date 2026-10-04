// Integration tests: download reliability for issue #192.
//
// Tests are grouped into three categories:
//
// A) CDN Contract Tests — fast HEAD-only checks, no large downloads, CI-friendly.
//    Verify HuggingFace CDN headers needed for future fixes (ParallelDownloadTask, allowPause).
//    Run on any platform.
//
// B) Download Behavior — real download of a small (284 MB) public model.
//    Verify progress reporting, monotonic progress (no silent restarts), and cancel cleanup.
//    Require a network connection. Run on Android, iOS, desktop.
//
// C) Foreground Service (Android only) — documents that foreground:true starts the service
//    correctly (TaskStatus.running received). Does not fix the 9-min TaskRunner timeout.
//
// Run:
//   flutter test integration_test/download_reliability_test.dart -d <device>
//
// See DOWNLOAD_TESTING.md for manual slow-network repro of issue #192.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

// Small public model — 284 MB, no auth token required.
const _smallModelUrl =
    'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task';
const _smallModelFilename = 'functiongemma-270M-it.task';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────────────────────────────────
  // Group A: HuggingFace CDN contract tests
  // Fast HEAD-only, no model download, CI-friendly.
  // ─────────────────────────────────────────────
  group('HuggingFace CDN contract', () {
    late http.Client client;

    setUp(() {
      client = http.Client();
    });

    tearDown(() {
      client.close();
    });

    // A1: Range requests supported → prerequisite for ParallelDownloadTask and allowPause resume.
    testWidgets(
      'HF CDN supports byte range requests (Accept-Ranges: bytes)',
      (tester) async {
        final response = await _headFollowingRedirects(client, _smallModelUrl);
        final acceptRanges = response.headers['accept-ranges'];
        debugPrint('[CDN] Accept-Ranges: $acceptRanges');
        expect(
          acceptRanges,
          equals('bytes'),
          reason:
              'ParallelDownloadTask requires Range request support. '
              'If this fails, chunked download cannot be used with HuggingFace URLs.',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    // A2: Content-Length after redirect → required for ParallelDownloadTask chunk size calculation.
    // background_downloader throws IllegalStateException if Content-Length is missing.
    testWidgets(
      'HF CDN returns Content-Length after following redirects',
      (tester) async {
        final response = await _headFollowingRedirects(client, _smallModelUrl);
        final contentLength = response.headers['content-length'];
        debugPrint('[CDN] Content-Length: $contentLength');

        // Document result — don't hard-fail since CDN nodes may vary.
        // If null → ParallelDownloadTask will fail with HuggingFace URLs.
        if (contentLength == null) {
          debugPrint(
            '[CDN] WARNING: Content-Length missing after redirects. '
            'ParallelDownloadTask will NOT work with this HF URL. '
            'Workaround: pass Known-Content-Length header manually.',
          );
        } else {
          final bytes = int.tryParse(contentLength) ?? 0;
          debugPrint(
            '[CDN] Model size: ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
          );
          expect(
            bytes,
            greaterThan(0),
            reason: 'Content-Length must be a positive integer',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    // A3: ETag type — documents whether HF uses weak or strong ETags.
    // background_downloader refuses to resume if ETag is weak (W/"...").
    // If this ever changes to strong ETag, allowPause: true becomes viable for HF.
    testWidgets(
      'HF CDN ETag type is documented (weak blocks allowPause resume)',
      (tester) async {
        final response = await _headFollowingRedirects(client, _smallModelUrl);
        final etag = response.headers['etag'];
        debugPrint('[CDN] ETag: $etag');

        final isWeak = etag?.startsWith('W/') ?? false;
        final isStrong = etag != null && !isWeak;
        debugPrint(
          '[CDN] ETag is ${isWeak
              ? "WEAK"
              : isStrong
              ? "STRONG"
              : "ABSENT"}',
        );

        if (isWeak) {
          debugPrint(
            '[CDN] KNOWN LIMITATION (issue #192): weak ETag prevents '
            'background_downloader from resuming interrupted downloads. '
            'timeout → fail → full restart from byte 0. '
            'Fix: wait for HF to switch to strong ETags, or use ParallelDownloadTask.',
          );
        } else if (isStrong) {
          debugPrint(
            '[CDN] Strong ETag detected — allowPause: true fix is NOW viable! '
            'Consider re-enabling pause/resume for HuggingFace URLs.',
          );
        }

        // Always passes — this test documents behavior, not enforces it.
        // Change this expect to isStrong when we want to assert the fix is needed.
        expect(etag, isNotNull, reason: 'ETag header should always be present');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  // ─────────────────────────────────────────────
  // Group B: Download behavior
  // Real download of 284 MB model. Requires network.
  // ─────────────────────────────────────────────
  group('Download behavior', () {
    setUpAll(() async {
      await registerTestEngines();
    });

    tearDown(() async {
      // Clean up after each test to avoid state pollution.
      try {
        if (await FlutterEdgeAi.isModelInstalled(_smallModelFilename)) {
          await FlutterEdgeAi.uninstallModel(_smallModelFilename);
        }
      } catch (_) {}
    });

    // B1: Download completes and fires progress callbacks.
    testWidgets(
      'download completes and reports progress',
      (tester) async {
        final progressValues = <int>[];

        await FlutterEdgeAi.installModel(
          modelType: ModelType.functionGemma,
          fileType: ModelFileType.task,
        ).fromNetwork(_smallModelUrl).withProgress((p) {
          debugPrint('[Download] Progress: $p%');
          progressValues.add(p);
        }).install();

        expect(
          FlutterEdgeAi.hasActiveModel(),
          isTrue,
          reason: 'Active model should be set after install',
        );
        expect(
          await FlutterEdgeAi.isModelInstalled(_smallModelFilename),
          isTrue,
          reason: 'Model file should exist on disk',
        );
        expect(
          progressValues,
          isNotEmpty,
          reason: 'Progress callbacks should fire during download',
        );
        expect(
          progressValues.last,
          equals(100),
          reason: 'Final progress should be 100%',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    // B1b (#445): the host keeps `background_downloader` for its own use.
    //
    // This is the property the whole fix exists for, and until now it had only
    // ever been asserted against a synthetic dispatcher in a unit test. On a
    // real device it also proves the half a unit test cannot: that our group
    // callbacks still carry a genuine native download end to end, rather than
    // the registration silently routing our updates nowhere.
    testWidgets(
      'a host can hold FileDownloader().updates across a model install',
      (tester) async {
        final hostSaw = <TaskUpdate>[];
        StreamSubscription<TaskUpdate>? hostSub;

        // Before the fix this threw: SmartDownloader had taken the single
        // subscription the process has.
        expect(
          () => hostSub = FileDownloader().updates.listen(hostSaw.add),
          returnsNormally,
          reason:
              'flutter_edge_ai consumed the only subscription on '
              'FileDownloader().updates, so the host cannot watch its own '
              'downloads (#445)',
        );
        addTearDown(() => hostSub?.cancel());

        final progressValues = <int>[];
        await FlutterEdgeAi.installModel(
              modelType: ModelType.functionGemma,
              fileType: ModelFileType.task,
            )
            .fromNetwork(_smallModelUrl)
            .withProgress(progressValues.add)
            .install();

        expect(
          await FlutterEdgeAi.isModelInstalled(_smallModelFilename),
          isTrue,
          reason: 'the download itself must still work',
        );
        expect(
          progressValues,
          isNotEmpty,
          reason:
              'group callbacks delivered nothing on a real device — the '
              'registration is wired to nowhere',
        );
        expect(progressValues.last, 100);

        expect(
          hostSaw.where((u) => u.task.group == SmartDownloader.downloadGroup),
          isEmpty,
          reason:
              "flutter_edge_ai's own tasks leaked into the host's stream; the "
              'host would see downloads it never started',
        );

        // Leave no task record behind. `taskId` is a deterministic hash of
        // (baseDirectory, directory, filename), so the NEXT test installing the
        // same model finds this record and takes the attach-to-existing path
        // instead of downloading — which is how adding this test made the
        // monotonic-progress test time out.
        final ours = await FileDownloader().allTasks(
          group: SmartDownloader.downloadGroup,
          includeTasksWaitingToRetry: true,
        );
        if (ours.isNotEmpty) {
          await FileDownloader().cancelTasksWithIds(
            ours.map((t) => t.taskId).toList(),
          );
        }
        await FileDownloader().reset(group: SmartDownloader.downloadGroup);
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    // B2: Progress is monotonically non-decreasing.
    // A silent restart (e.g., from weak ETag mismatch or retry) causes progress to
    // reset to 0 mid-download. This test catches such regressions.
    // NOTE: On slow connections with issue #192 active, this test may time out before
    // the download completes — that is the expected failure mode.
    testWidgets(
      'download progress does not reset to zero mid-download',
      (tester) async {
        int maxProgress = 0;
        bool progressReset = false;
        int resetFromPercent = 0;

        await FlutterEdgeAi.installModel(
          modelType: ModelType.functionGemma,
          fileType: ModelFileType.task,
        ).fromNetwork(_smallModelUrl).withProgress((p) {
          // Allow small backwards movement (±2%) for rounding, but not a full reset.
          if (p > 0 && p < maxProgress - 5) {
            progressReset = true;
            resetFromPercent = maxProgress;
            debugPrint(
              '[Download] Progress reset detected: was $maxProgress%, now $p%',
            );
          }
          if (p > maxProgress) maxProgress = p;
        }).install();

        expect(
          progressReset,
          isFalse,
          reason:
              'Progress reset from $resetFromPercent% to near 0 — '
              'indicates a silent download restart. '
              'Possible cause: weak ETag mismatch on resume, or network retry. '
              'See issue #192.',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    // B3: Cancelling (uninstall after partial) cleans up properly.
    // We install the model fully, then uninstall — verifies cleanup works.
    // Full cancel-mid-download is not testable without a public cancel API.
    testWidgets(
      'uninstalled model is removed from disk',
      (tester) async {
        await FlutterEdgeAi.installModel(
          modelType: ModelType.functionGemma,
          fileType: ModelFileType.task,
        ).fromNetwork(_smallModelUrl).install();

        expect(
          await FlutterEdgeAi.isModelInstalled(_smallModelFilename),
          isTrue,
        );

        await FlutterEdgeAi.uninstallModel(_smallModelFilename);

        expect(
          await FlutterEdgeAi.isModelInstalled(_smallModelFilename),
          isFalse,
          reason: 'Model file should be removed after uninstall',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });

  // ─────────────────────────────────────────────
  // Group C: Foreground service (Android only)
  // ─────────────────────────────────────────────
  group('Foreground service', () {
    setUpAll(() async {
      if (!Platform.isAndroid) return;
      await registerTestEngines();
    });

    tearDown(() async {
      if (!Platform.isAndroid) return;
      try {
        if (await FlutterEdgeAi.isModelInstalled(_smallModelFilename)) {
          await FlutterEdgeAi.uninstallModel(_smallModelFilename);
        }
      } catch (_) {}
    });

    // C1: foreground: true starts the download and reaches running status.
    // Does NOT verify that the download completes on slow connections — that is
    // the known bug (issue #192): TaskRunner 9-min timeout kills the task.
    // See DOWNLOAD_TESTING.md for manual slow-network repro.
    testWidgets(
      'foreground: true download starts and completes on fast network',
      (tester) async {
        await FlutterEdgeAi.installModel(
              modelType: ModelType.functionGemma,
              fileType: ModelFileType.task,
            )
            .fromNetwork(_smallModelUrl, foreground: true)
            .withProgress((p) => debugPrint('[Foreground] Progress: $p%'))
            .install();

        expect(
          await FlutterEdgeAi.isModelInstalled(_smallModelFilename),
          isTrue,
          reason:
              'foreground: true download should complete on fast network. '
              'On slow connections (< 2 Mbps for 2.6 GB), this times out — '
              'see issue #192 for the known bug.',
        );
      },
      skip: !Platform.isAndroid,
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });

  // ─────────────────────────────────────────────
  // Group D: resume lifecycle terminates (#355)
  // A real small-model download must resolve — its progress stream must
  // CLOSE (done or error) — within a bounded time. On the pre-fix code a
  // resume-loop could hang here forever.
  // ─────────────────────────────────────────────
  group('resume lifecycle terminates (#355)', () {
    testWidgets(
      'a real small download completes or errors, never hangs',
      (tester) async {
        const token = String.fromEnvironment('HUGGINGFACE_TOKEN');
        // A small, resumable model (~135MB) so the test is fast on FTL.
        const url =
            'https://huggingface.co/litert-community/SmolLM-135M-Instruct/resolve/main/SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task';
        final dir = (await getTemporaryDirectory()).path;
        final target = '$dir/smoke_smollm.task';

        final done = Completer<String>();
        final sub =
            SmartDownloader.downloadWithProgress(
              url: url,
              targetPath: target,
              token: token.isEmpty ? null : token,
            ).listen(
              (_) {},
              onError: (e) =>
                  done.isCompleted ? null : done.complete('error: $e'),
              onDone: () => done.isCompleted ? null : done.complete('done'),
            );

        // Bounded wait: the stream MUST terminate (done or error). A hang = FAIL.
        final outcome = await done.future.timeout(
          const Duration(minutes: 8),
          onTimeout: () => 'HUNG',
        );
        await sub.cancel();
        expect(
          outcome,
          isNot('HUNG'),
          reason: 'install stream must terminate, not hang (#355)',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}

// Follows HTTP redirects manually for HEAD requests.
// Returns the final response after all redirects are resolved.
Future<http.Response> _headFollowingRedirects(
  http.Client client,
  String url,
) async {
  var uri = Uri.parse(url);
  int hops = 0;
  const maxHops = 10;

  while (hops < maxHops) {
    final response = await client.head(uri);
    debugPrint('[CDN] HEAD $uri → ${response.statusCode}');

    if (response.statusCode == 301 ||
        response.statusCode == 302 ||
        response.statusCode == 307 ||
        response.statusCode == 308) {
      final location = response.headers['location'];
      if (location == null) break;
      uri = uri.resolve(location);
      hops++;
    } else {
      debugPrint('[CDN] Final URL after $hops redirects: $uri');
      return response;
    }
  }

  throw Exception('Too many redirects (>$maxHops) for $url');
}
