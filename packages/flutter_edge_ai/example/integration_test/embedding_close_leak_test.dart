// Closing an embedder in the middle of a batch must free its native model.
//
// Before core 2.1.3 the worker served its port one `await for` turn at a
// time, so a close queued behind a batch waited for the whole batch; close()
// gave up after 5 s and killed the isolate, and a killed isolate never runs
// `pass.close()`. The LiteRT model stayed resident for the life of the
// process. This measures that from the OS side with
// `flutter_edge_ai_diagnostics`, so it runs on Android and iOS only.
//
// What is measured, and why:
// - Every snapshot except "busy" follows a forced full GC. The worker isolate
//   shares the app's isolate-group heap, so the tokenizer it built (60-90 MiB
//   of Dart objects for EmbeddingGemma's SentencePiece vocabulary on a Pixel
//   5) stays there as garbage after close until the VM collects it. Without
//   the GC the closed number follows the GC schedule, not the native model.
// - On Android the leak check uses anonymousBytes + fileBackedBytes. A model
//   leaked by core 2.1.2 keeps its mmapped weights (clean file pages) and its
//   packed weights (malloc'd, anonymous) — and anonymous pages read back from
//   zram are counted as clean, so they move from the first number to the
//   second. On a Pixel 5 that moved 55-65 MiB of a leaked model out of
//   anonymousBytes in two of three runs, which then showed a 21-27% residual
//   for a model that was never freed. iOS has no fileBackedBytes; its
//   footprint keeps compressed pages, so anonymousBytes alone is the check
//   there.
//
// Model: EmbeddingGemma 300M seq256 (the files the litertlm_ffi_test #299
// group uses). The Hugging Face repo is gated, so the files are staged:
//   Android: /data/local/tmp/flutter_gemma_test/ (adb push, or FTL
//            --other-files).
//   iOS:     copy both files into example/assets/test/ (gitignored); the
//            test reads them in place from the app bundle.
//
// Run (debug: the forced GC needs the VM service):
//   flutter test integration_test/embedding_close_leak_test.dart -d <device>
//
// No setUp/setUpAll: everything that can fail runs inside the test body, so
// a failure is a failed test, never an absent one.
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vm_service/vm_service.dart' show VmService;
import 'package:vm_service/vm_service_io.dart' show vmServiceConnectUri;

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelName = 'embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerName = 'sentencepiece.model';
const _androidDir = '/data/local/tmp/flutter_gemma_test';

const _batchSize = 300;

// About fifty words, so every item is a full forward pass.
const _sentence =
    'Renewable energy is reshaping the global power grid as utilities add '
    'solar farms, offshore wind turbines and large battery banks, while '
    'engineers redesign transmission lines, regulators rewrite market rules, '
    'and households install heat pumps and rooftop panels that turn ordinary '
    'homes into small power stations feeding electricity back to their '
    'neighbours.';

const _closedBeforeRun = 'closed before this request ran';

const _mb = 1024 * 1024;

/// Where a staged file is, without holding it on the Dart heap: the pushed
/// path on Android, the bundled asset read in place on iOS. Only if neither
/// exists is the asset copied through `rootBundle` — before the baseline.
Future<String> _resolve(String name) async {
  if (Platform.isAndroid) {
    final pushed = File('$_androidDir/$name');
    if (pushed.existsSync()) return pushed.path;
  }
  if (Platform.isIOS) {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File(
      '$appDir/Frameworks/App.framework/flutter_assets/assets/test/$name',
    );
    if (bundled.existsSync()) return bundled.path;
  }
  final docs = await getApplicationDocumentsDirectory();
  final copy = File('${docs.path}/$name');
  if (copy.existsSync()) return copy.path;
  final bytes = await rootBundle.load('assets/test/$name');
  await copy.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return copy.path;
}

/// This isolate's VM service: a forced full GC and the Dart heap in use.
final class _Vm {
  _Vm._(this._service, this._isolateId);

  final VmService _service;
  final String _isolateId;

  static Future<_Vm> connect() async {
    final info = await developer.Service.getInfo();
    final uri = info.serverWebSocketUri;
    final isolateId = developer.Service.getIsolateId(Isolate.current);
    if (uri == null || isolateId == null) {
      fail(
        'no VM service in this build; run in debug mode — the forced GC '
        'this measurement depends on needs it',
      );
    }
    return _Vm._(await vmServiceConnectUri(uri.toString()), isolateId);
  }

  Future<void> collect() => _service.getAllocationProfile(_isolateId, gc: true);

  Future<int?> heapUsage() async =>
      (await _service.getMemoryUsage(_isolateId)).heapUsage;

  Future<void> dispose() => _service.dispose();
}

/// One reading: anonymousBytes, the clean pages next to it (Android), and
/// the two together — the number the leak check uses.
typedef _Reading = ({int anonymous, int? clean, int resident});

String _mib(int? bytes) =>
    bytes == null ? '-' : (bytes / _mb).toStringAsFixed(1);

Future<_Reading> _read(_Vm vm, String phase, {bool gc = true}) async {
  if (gc) await vm.collect();
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  final heap = await vm.heapUsage();
  final anonymous = snapshot.anonymousBytes;
  if (anonymous == null) {
    fail('anonymousBytes is null on this device at $phase ($snapshot)');
  }
  final clean = snapshot.fileBackedBytes;
  if (Platform.isAndroid && clean == null) {
    fail('fileBackedBytes is null on Android at $phase ($snapshot)');
  }
  final reading = (
    anonymous: anonymous,
    clean: clean,
    resident: anonymous + (clean ?? 0),
  );
  // ignore: avoid_print
  print(
    '[close-leak] $phase${gc ? ' (after GC)' : ''}: '
    'anonymousMiB=${_mib(anonymous)} fileBackedMiB=${_mib(clean)} '
    'residentMiB=${_mib(reading.resident)} dartHeapMiB=${_mib(heap)}',
  );
  return reading;
}

/// One batch item: the vector arrived, or the error it failed with.
typedef _Outcome = ({int index, bool ok, String? error});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('closing an embedder mid-batch frees its native model', (
    tester,
  ) async {
    expect(
      FlutterEdgeAiDiagnostics.isSupported,
      isTrue,
      reason: 'memorySnapshot() reads Android /proc or iOS Mach counters only',
    );

    final vm = await _Vm.connect();
    try {
      await registerTestEngines();
      final modelPath = await _resolve(_modelName);
      final tokenizerPath = await _resolve(_tokenizerName);
      // ignore: avoid_print
      print('[close-leak] model=$modelPath tokenizer=$tokenizerPath');
      await FlutterEdgeAi.installEmbedder()
          .modelFromFile(modelPath)
          .tokenizerFromFile(tokenizerPath)
          .install();

      final baseline = await _read(vm, 'baseline');
      final model = await FlutterEdgeAi.getActiveEmbedder();
      var closeStarted = false;
      try {
        final loaded = await _read(vm, 'loaded');

        // generateEmbeddings(texts) is Future.wait over one worker request per
        // text, and Future.wait reports only the first error. So the batch is
        // sent as one-text generateEmbeddings calls from one synchronous loop:
        // the same 300 requests, in the same order, in the same event-loop
        // turn as generateEmbeddings(List.filled(300, ...)). Future.wait over
        // them is that call's outcome; each one alone is an item's.
        final calls = [
          for (var i = 0; i < _batchSize; i++)
            model.generateEmbeddings([_sentence]),
        ];
        final batch = Future.wait(
          calls,
        ).then<Object?>((_) => null, onError: (Object e) => e);
        final items = [
          for (var i = 0; i < _batchSize; i++)
            calls[i].then<_Outcome>(
              (_) => (index: i, ok: true, error: null),
              onError: (Object e) => (index: i, ok: false, error: '$e'),
            ),
        ];

        await Future<void>.delayed(const Duration(milliseconds: 300));
        final busy = await _read(vm, 'busy', gc: false);

        closeStarted = true;
        final stopwatch = Stopwatch()..start();
        await model.close();
        stopwatch.stop();
        final closeMs = stopwatch.elapsedMilliseconds;

        final outcomes = await Future.wait(items);
        final batchError = await batch;

        await Future<void>.delayed(const Duration(seconds: 1));
        final closed = await _read(vm, 'closed +1 s');

        final succeeded = outcomes.where((o) => o.ok).length;
        final failed = outcomes.where((o) => !o.ok).toList();
        final firstFailure = failed.isEmpty ? null : failed.first.index;
        final otherErrors = {
          for (final o in failed)
            if (!o.error!.contains(_closedBeforeRun)) o.error!,
        };

        final loadDelta = loaded.resident - baseline.resident;
        final residual = closed.resident - baseline.resident;

        // ignore: avoid_print
        print(
          '[close-leak] RESULT platform=${Platform.operatingSystem} '
          'anonymousMiB baseline=${_mib(baseline.anonymous)} '
          'loaded=${_mib(loaded.anonymous)} busy=${_mib(busy.anonymous)} '
          'closed=${_mib(closed.anonymous)} | '
          'fileBackedMiB baseline=${_mib(baseline.clean)} '
          'loaded=${_mib(loaded.clean)} closed=${_mib(closed.clean)} | '
          'resident loadDeltaMiB=${_mib(loadDelta)} '
          'residualMiB=${_mib(residual)} '
          '(${(residual * 100 / loadDelta).toStringAsFixed(0)}%) | '
          'closeMs=$closeMs succeeded=$succeeded failed=${failed.length} '
          'firstFailedIndex=$firstFailure',
        );
        // ignore: avoid_print
        print('[close-leak] batch error: $batchError');
        if (otherErrors.isNotEmpty) {
          // ignore: avoid_print
          print('[close-leak] other item errors: $otherErrors');
        }

        // Without a measurable load the memory assertion proves nothing.
        expect(
          loadDelta,
          greaterThan(64 * _mb),
          reason:
              'loading EmbeddingGemma raised resident memory by only '
              '${_mib(loadDelta)} MiB; the probe cannot see the model',
        );

        // The old close waited 5 s for an ack it could not get, then killed
        // the worker. Now it waits for the one request in flight: 0.1-0.6 s
        // on a Pixel 5 and a Pixel 8 Pro (one item takes about 0.7 s on the
        // Pixel 5).
        expect(
          closeMs,
          lessThan(3000),
          reason:
              'close() took $closeMs ms; it should wait only for the one '
              'request in flight',
        );

        // The batch was still queued: close fails what had not started.
        expect(
          batchError,
          isNotNull,
          reason: 'the whole batch ran before close',
        );
        expect('$batchError', contains(_closedBeforeRun));
        expect(failed, isNotEmpty);
        expect(
          otherErrors,
          isEmpty,
          reason: 'every failed item must be one that close cancelled',
        );
        // Served in order: everything before the first cancelled item ran.
        expect(succeeded, firstFailure, reason: 'successes must be a prefix');

        // The native model is gone. Pixel 5 (Android 11) and Pixel 8 Pro
        // (Android 14), after GC: core 2.1.3 leaves 10-16% of what the load
        // added (24-37 MiB: libraries that stay loaded and allocator caches,
        // flat over two more load/close cycles on the Pixel 5); core 2.1.2
        // leaves 72-88% on the Pixel 5, and 165-185 MiB more on each further
        // cycle. Half the load delta sits between the two.
        expect(
          residual,
          lessThan(loadDelta ~/ 2),
          reason:
              'after close, resident memory is ${_mib(residual)} MiB above '
              'baseline, of ${_mib(loadDelta)} MiB the load added — the '
              'native model is still resident',
        );
      } finally {
        // A failure before close() must not leave the worker behind; after
        // it, close() has already run.
        if (!closeStarted) await model.close();
      }
    } finally {
      await vm.dispose();
    }
  });
}
