/// Upstream LiteRT-LM #2699 retest — does the Android OpenCL GPU per-turn leak
/// still reproduce?
///
/// This mirrors the configuration from the two CONFIRMED downstream reports
/// rather than a convenient minimal loop, because "did not reproduce" only
/// means anything when the repro matches:
///
///   flutter_edge_ai #348 (Pixel 4a, Android 13, GPU): openChat per turn +
///     generateChatResponseAsync streaming, maxTokens 4096, temp 0.2, topK 20,
///     tokenBuffer 256 -> Native Heap ratcheted 150-300 MB per inference.
///   flutter_edge_ai #402 (Vivo iQOO, Android 12, GPU): createChat per turn +
///     streaming, maxTokens 2048 -> ~65 MB per inference, OOM after ~18.
///
/// An earlier version of this test used the raw session API, non-streaming
/// getResponse(), and maxTokens 1024 — a different code path with a 4x smaller
/// KV cache. It showed no growth, which said nothing about the reported bug.
///
/// Model is pushed by Firebase Test Lab via
///   --other-files /data/local/tmp/flutter_gemma_test/Qwen3-0.6B.litertlm=<local>
/// Locally: adb push Qwen3-0.6B.litertlm /data/local/tmp/flutter_gemma_test/
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _dir = '/data/local/tmp/flutter_gemma_test';
const _qwen3 = '$_dir/Qwen3-0.6B.litertlm';

const _turns = 8;

/// #402 drove ~100-char inputs; keep the prompt in that range so the per-turn
/// prefill is comparable to the reports rather than trivially short.
const _prompt =
    'Summarise in one sentence why coastal towns rely on tourism during the '
    'summer months and what happens to them in winter.';

/// Native resident set size in kB, straight from the kernel. `/proc/self/status`
/// needs no permission and reports VmRSS already in kB — unlike `statm`, which
/// is in pages and would need the page size (16 KB on newer Android, 4 KB
/// elsewhere) to interpret correctly.
/// Throws rather than returning a sentinel: an unreadable VmRSS would make every
/// sample equal, growth compute to 0, and all three thresholds pass — a broken
/// measurement is indistinguishable from a clean result.
int _rssKb() {
  final line = File('/proc/self/status').readAsLinesSync().firstWhere(
    (l) => l.startsWith('VmRSS:'),
    orElse: () => '',
  );
  final kb = int.tryParse(RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '');
  if (kb == null || kb <= 0) {
    throw StateError(
      'could not read VmRSS from /proc/self/status (line: "$line") — '
      'refusing to report a leak measurement taken with a broken instrument',
    );
  }
  return kb;
}

/// One engine, [turns] throwaway chats — the exact shape both reports used.
/// Returns RSS in kB before the first turn, after each turn, and after the
/// engine itself is closed.
Future<List<int>> _turnLoop(PreferredBackend backend, int turns) async {
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 4096, // #348: KV-cache size
    preferredBackend: backend,
  );

  // The FFI runtime falls back silently: `gpu` resolves to [gpu, cpu], and a
  // failed OpenCL init is only a printed warning (backend_preference.dart).
  // On a device where the vendor ICD does not load (#324) the "GPU" leg would
  // run on CPU, show flat RSS, and report #2699 as fixed on a build where the
  // suspect path never executed. Assert what actually initialised.
  expect(
    model.activeBackend,
    backend,
    reason:
        'requested $backend but the runtime initialised '
        '${model.activeBackend} — this measurement would describe the wrong '
        'backend',
  );

  final rss = <int>[_rssKb()];
  // close() must run even if a turn throws. It was written when getActiveModel()
  // deduped on the model's NAME only, so a model left open by a failed CPU run
  // was handed straight back to the GPU run, which then measured CPU, saw no
  // growth, and PASSED — hiding the very leak this file exists to catch.
  // `ActiveModelParams` now compares preferredBackend too, so that particular
  // hand-back no longer happens; the close still keeps one run's model and its
  // native memory from leaking into the next measurement.
  try {
    for (var i = 0; i < turns; i++) {
      final chat = await model.openChat(
        modelType: ModelType.qwen3,
        temperature: 0.2,
        topK: 20,
        tokenBuffer: 256,
        enableThinking: false,
      );
      var chunks = 0;
      try {
        await chat.addQueryChunk(const Message(text: _prompt, isUser: true));
        await for (final _ in chat.generateChatResponseAsync()) {
          chunks++; // count every ModelResponse, thinking included
        }
      } finally {
        await chat.close();
      }
      // A stream that yields nothing completes normally, does no work, and
      // leaves RSS flat — which this harness would read as "no leak". That is
      // not hypothetical here: this branch carries a runtime probe for the
      // v0.15.0 stream-callback ABI change, and a probe that guesses wrong
      // produces exactly zero chunks.
      expect(
        chunks,
        greaterThan(4),
        reason:
            'turn ${i + 1} generated $chunks chunks — no generation happened, '
            'so any RSS reading from this run is meaningless',
      );
      rss.add(_rssKb());
    }
  } finally {
    await model.close();
  }
  rss.add(_rssKb());
  return rss;
}

/// Growth measured from *after* the first turn.
///
/// The first generation legitimately allocates weights, KV cache and delegate
/// scratch — hundreds of MB on every backend. Counting it makes a healthy run
/// look like a leak (the first pass of this test flagged CPU at +627 MB, all of
/// it turn one). A leak is a *ratchet*: memory that keeps climbing once the
/// engine is warm, so that is what to measure.
double _steadyGrowthMb(List<int> rss) => (rss[rss.length - 2] - rss[1]) / 1024;

void _report(String label, List<int> rss) {
  final perTurn = <String>[];
  for (var i = 1; i < rss.length - 1; i++) {
    perTurn.add('${((rss[i] - rss[i - 1]) / 1024).toStringAsFixed(1)}MB');
  }
  final firstTurn = (rss[1] - rss.first) / 1024;
  final afterClose = (rss.last - rss.first) / 1024;
  // ignore: avoid_print
  print(
    '[#2699/$label] start=${(rss.first / 1024).toStringAsFixed(0)}MB '
    'firstTurn=+${firstTurn.toStringAsFixed(1)}MB '
    'perTurn=[${perTurn.join(", ")}] '
    'steadyGrowth=+${_steadyGrowthMb(rss).toStringAsFixed(1)}MB '
    'afterEngineClose=+${afterClose.toStringAsFixed(1)}MB',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    expect(
      File(_qwen3).existsSync(),
      isTrue,
      reason: 'model missing at $_qwen3',
    );
    await FlutterEdgeAi.installModel(
      modelType: ModelType.qwen3,
      fileType: ModelFileType.litertlm,
    ).fromFile(_qwen3).install();
  });

  group('#2699 OpenCL per-turn leak', () {
    testWidgets('CPU control — RSS must stay flat', (_) async {
      final rss = await _turnLoop(PreferredBackend.cpu, _turns);
      _report('cpu', rss);
      expect(
        _steadyGrowthMb(rss),
        lessThan(50),
        reason:
            'CPU was flat in every report; growth here means the repro '
            'itself is wrong, not that the GPU bug moved',
      );
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('GPU (OpenCL) — the suspect path', (_) async {
      final rss = await _turnLoop(PreferredBackend.gpu, _turns);
      _report('gpu', rss);
      final growthMb = _steadyGrowthMb(rss);
      // #348 measured 150-300 MB/turn, #402 ~65 MB/turn => >450 MB across
      // turns 2-8 at the low end. 50 MB sits an order of magnitude below
      // that and well above allocator noise, so neither verdict rests on a
      // borderline number.
      expect(
        growthMb,
        lessThan(50),
        reason:
            'FAIL here = #2699 still reproduces '
            '(steady-state growth ${growthMb.toStringAsFixed(1)}MB across '
            'turns 2-$_turns)',
      );
    }, timeout: const Timeout(Duration(minutes: 25)));

    testWidgets(
      'GPU — engine teardown does not reclaim either (#402 refinement)',
      (_) async {
        // #402 reported RSS still climbing when the engine is destroyed and
        // recreated every few turns, i.e. the allocations outlive the engine.
        final before = _rssKb();
        for (var round = 0; round < 2; round++) {
          await _turnLoop(PreferredBackend.gpu, 4);
        }
        final growthMb = (_rssKb() - before) / 1024;
        // ignore: avoid_print
        print(
          '[#2699/gpu-recreate] afterTwoEngineCycles=+'
          '${growthMb.toStringAsFixed(1)}MB',
        );
        expect(
          growthMb,
          lessThan(200),
          reason:
              'FAIL = allocations survive full engine teardown, as #402 '
              'reported (grew ${growthMb.toStringAsFixed(1)}MB)',
        );
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  });
}
