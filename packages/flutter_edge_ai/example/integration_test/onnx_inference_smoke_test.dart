// ONNX ORT-GenAI Android arm64 device-gate smoke test (hardened Android
// plan, Task 2). Android phones only (DDP) — not meant to run on a desktop CI
// host (guarded by `skip: !Platform.isAndroid` below).
//
// Deliberately drives `GenAiFfiClient` DIRECTLY, bypassing
// `OnnxEngine.canHandle`'s host gate and `FlutterEdgeAi.installModel()` —
// identical rationale to the Linux/Windows device-gate scripts
// (`run_onnx_integration_linux_gcloud.sh` / `_windows.sh`): the registry
// gate widens only after THIS test's numbers pass the go/no-go bar (see
// `onnx_engine.dart`'s `_isSupportedHost`), and ORT-GenAI models are whole
// DIRECTORIES (genai_config.json + .onnx[+.onnx_data] + tokenizer files) —
// `RuntimeConfig.modelPath` only carries a single resolved file, so
// `FlutterEdgeAi.installModel()` can't install this bundle yet (known gap,
// see `onnx_engine.dart`'s `createModel` doc). Mirrors
// `onnx_generation_host_smoke_test.dart`'s (flutter_edge_ai_onnx package) shape
// but adds in-test HTTP download (no host filesystem to point env vars at on
// a real device) and RSS/VmHWM sampling (the device-specific half of the
// go/no-go this repo's desktop gates didn't need).
//
// MODEL PROVISIONING: in-test HTTP download of
// microsoft/Phi-3.5-mini-instruct-onnx (cpu_and_mobile/cpu-int4-awq-block-
// 128-acc-level-4 — same model/variant as the macOS/Linux/Windows gates, so
// the tok/s numbers stay comparable) into
// `getApplicationDocumentsDirectory()`. The repo is public/ungated — no HF
// token needed (verified: a plain HEAD/GET redirects straight to the CDN,
// no 401/403), into the app's own documents dir.
//
// A phone's own download can be far too slow for a DDP session (DDP Galaxy
// S25 Ultra, 2026-11-02: the 2.7 GB .onnx.data reached 3.8% in 15 minutes).
// So when the directory is already staged on the phone, the test reads it
// there and downloads nothing:
//   adb shell mkdir -p /data/local/tmp/flutter_gemma_test/phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4
//   adb push <every file of _modelFiles> /data/local/tmp/flutter_gemma_test/phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4/
//   adb shell chmod 644 /data/local/tmp/flutter_gemma_test/phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4/*
// (the app reads the files as another user). A staged directory that lacks a
// file, or holds one the app cannot read, fails the test instead of being
// topped up from the network.
//
// GO/NO-GO BAR this test's printed numbers are judged against (see the
// Android plan's Task 4 — NOT asserted here; a hard throughput assertion
// would make this test brittle across device models):
//   go:    sustained decode tok/s median >= 5 across turns, TTFT <= 2s
//   no-go: sustained decode tok/s < 4 under thermal load
//   memory: no SIGKILL / lowmemorykiller; printed VmHWM = the reported
//           Android RAM number.
//
// Run on a DDP phone with `.claude/skills/ddp-device-test/run_instrumented.sh`
// (`flutter test` cannot attach through DDP's adb forwarder).
import 'dart:io';

// ignore: implementation_imports — drives onnx's ORT-GenAI FFI client directly
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Same model/variant the macOS/Linux/Windows device-gate tests already use
/// (`onnx_genai_bundle_test.dart` and friends) — keeps the tok/s numbers
/// comparable across platforms.
const _repoBase =
    'https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx/resolve/'
    'main/cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4';

/// The full file set from the verified-working macOS smoke-test model
/// directory (config.json/configuration_phi3.py are HF-tooling-only, unused
/// by ORT-GenAI's C API, but included anyway — they're a few KB against a
/// ~2.7 GB download, and parity with the known-good directory removes any
/// doubt about an undocumented runtime dependency on them).
const _modelFiles = [
  'genai_config.json',
  'config.json',
  'configuration_phi3.py',
  'phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4.onnx',
  'phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4.onnx.data',
  'tokenizer.json',
  'tokenizer_config.json',
  'special_tokens_map.json',
];

/// Where `adb push` stages the model directory (the example's other Android
/// tests read their models from `/data/local/tmp/flutter_gemma_test/` too).
const _stagedDirName =
    'phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4';
const _stagedDir = '/data/local/tmp/flutter_gemma_test/$_stagedDirName';

/// The staged model directory when it exists, after checking that every file
/// of [_modelFiles] is there, non-empty and readable by the app; null when
/// nothing is staged.
Directory? _stagedModelDir() {
  final dir = Directory(_stagedDir);
  if (!dir.existsSync()) return null;
  final missing = <String>[];
  final unreadable = <String>[];
  for (final name in _modelFiles) {
    final file = File('${dir.path}/$name');
    if (!file.existsSync() || file.lengthSync() == 0) {
      missing.add(name);
      continue;
    }
    try {
      file.openSync().closeSync();
    } on FileSystemException {
      unreadable.add(name);
    }
  }
  final problems = [
    if (missing.isNotEmpty) 'lacks ${missing.join(', ')}',
    if (unreadable.isNotEmpty)
      'cannot read ${unreadable.join(', ')} (chmod 644)',
  ];
  if (problems.isNotEmpty) {
    throw StateError(
      '$_stagedDir is staged but ${problems.join(' and ')}: push every file '
      'of the model directory readable, or remove the directory to download',
    );
  }
  return dir;
}

/// Downloads [url] to [dest] via a temp-then-rename (an interrupted FTL run
/// never leaves a partial file that a retry would mistake for complete —
/// same pattern as `hook/build.dart`'s `_downloadVerifyExtract`). Skips the
/// network entirely if [dest] already exists non-empty (re-running this test
/// locally against a warm app-data dir shouldn't re-pull 2.7 GB).
Future<void> _downloadFile(HttpClient client, String url, File dest) async {
  if (dest.existsSync() && dest.lengthSync() > 0) {
    // ignore: avoid_print
    print(
      '[onnx android smoke] cached: ${dest.path} (${dest.lengthSync()} bytes)',
    );
    return;
  }
  final tmp = File('${dest.path}.part');
  final request = await client.getUrl(Uri.parse(url));
  request.followRedirects = true; // HF resolve/main -> CDN redirect chain.
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw StateError('download failed (HTTP ${response.statusCode}) for $url');
  }
  final sink = tmp.openWrite();
  var received = 0;
  final total = response.contentLength;
  final progressSw = Stopwatch()..start();
  try {
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      if (progressSw.elapsedMilliseconds > 10000) {
        progressSw.reset();
        final label = total > 0
            ? '${(received * 100 / total).toStringAsFixed(1)}%'
            : '$received bytes';
        // ignore: avoid_print
        print('[onnx android smoke] ${dest.uri.pathSegments.last}: $label');
      }
    }
  } finally {
    await sink.flush();
    await sink.close();
  }
  await tmp.rename(dest.path);
}

/// Native RSS + peak-RSS in kB, straight from the kernel — same source
/// `opencl_leak_2699_test.dart` uses for the OpenCL leak retest. VmHWM
/// ("high water mark") is the peak RSS the process has EVER hit, which is
/// exactly the Android RAM number the go/no-go cares about (a mid-run sample
/// of plain VmRSS could understate the transient prefill peak).
({int rssKb, int hwmKb}) _memKb() {
  final lines = File('/proc/self/status').readAsLinesSync();
  int? rss;
  int? hwm;
  for (final line in lines) {
    if (line.startsWith('VmRSS:')) {
      rss = int.tryParse(RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '');
    } else if (line.startsWith('VmHWM:')) {
      hwm = int.tryParse(RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '');
    }
  }
  if (rss == null || rss <= 0 || hwm == null || hwm <= 0) {
    throw StateError(
      'could not read VmRSS/VmHWM from /proc/self/status — refusing to '
      'report a memory measurement taken with a broken instrument',
    );
  }
  return (rssKb: rss, hwmKb: hwm);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ONNX GenAI Android arm64 device gate: Phi-3.5-mini int4 through the '
    'bundled CodeAsset .so pair — functional + TTFT/decode-tok/s + RSS',
    (tester) async {
      await tester.runAsync(() async {
        final staged = _stagedModelDir();
        final Directory modelDir;
        if (staged != null) {
          modelDir = staged;
          // ignore: avoid_print
          print('[onnx android smoke] using the staged model at $_stagedDir');
        } else {
          // ignore: avoid_print
          print(
            '[onnx android smoke] no staged model at $_stagedDir, downloading',
          );
          final docsDir = await getApplicationDocumentsDirectory();
          modelDir = Directory('${docsDir.path}/onnx_android_smoke_model');
          if (!modelDir.existsSync()) modelDir.createSync(recursive: true);

          final downloadClient = HttpClient();
          try {
            for (final name in _modelFiles) {
              await _downloadFile(
                downloadClient,
                '$_repoBase/$name',
                File('${modelDir.path}/$name'),
              );
            }
          } finally {
            downloadClient.close(force: true);
          }
        }

        final configFile = File('${modelDir.path}/genai_config.json');
        expect(
          configFile.existsSync(),
          isTrue,
          reason:
              'no genai_config.json in the model directory at '
              '${configFile.path}',
        );

        final beforeLoad = _memKb();
        // ignore: avoid_print
        print('[onnx android smoke] RSS before load: ${beforeLoad.rssKb} kB');

        final client = GenAiFfiClient();
        final loadSw = Stopwatch()..start();
        // Same contextWindow as every other platform's device gate — keeps
        // the KV-cache budget (and thus memory footprint) comparable.
        await client.load(modelDir.path, contextWindow: 1024);
        loadSw.stop();
        final afterLoad = _memKb();
        // ignore: avoid_print
        print(
          '[onnx android smoke] model load took '
          '${loadSw.elapsedMilliseconds} ms (this covers dlopen of both '
          'bundled CodeAsset .so files + OgaCreateModel/OgaCreateTokenizer — '
          'the end-to-end proof the flat-APK co-location works on-device); '
          'RSS after load: ${afterLoad.rssKb} kB '
          '(delta ${afterLoad.rssKb - beforeLoad.rssKb} kB)',
        );

        // >=3 turns on the SAME generator (KV cache persists across turns,
        // isFirstTurn only on the first) — the go/no-go wants a sustained
        // decode number, not a single cold-start sample.
        const prompts = [
          'Write a detailed, at least 150-word paragraph describing the '
              'water cycle, covering evaporation, condensation, and '
              'precipitation.',
          'Now write another, completely different long paragraph, this '
              'time about the rock cycle.',
          'Explain in a few sentences why the sky appears blue during the '
              'day.',
        ];

        final decodeTokPerSec = <double>[];
        for (var i = 0; i < prompts.length; i++) {
          final turnNumber = i + 1;
          final ttftSw = Stopwatch()..start();
          int? ttftMs;
          final buffer = StringBuffer();
          await for (final chunk in client.generate(
            GenAiTurn(
              userContent: prompts[i],
              isFirstTurn: turnNumber == 1,
              maxOutputTokens: 64,
            ),
          )) {
            ttftMs ??= ttftSw.elapsedMilliseconds; // time to FIRST chunk only
            buffer.write(chunk);
          }
          final stats = client.lastGenerationStats;
          final text = buffer.toString();

          expect(
            text.trim(),
            isNotEmpty,
            reason:
                'turn $turnNumber produced no text — either generation '
                'failed silently or the bundled genai .so failed to '
                'resolve onnxruntime at runtime',
          );
          expect(
            stats,
            isNotNull,
            reason:
                'turn $turnNumber completed but left no '
                'GenAiGenerationStats',
          );

          final mem = _memKb();
          final tps = stats!.tokensPerSecond;
          if (tps != null) decodeTokPerSec.add(tps);
          // ignore: avoid_print
          print(
            '[onnx android smoke] turn $turnNumber: TTFT=${ttftMs}ms '
            'prompt=${stats.promptTokens} generated=${stats.generatedTokens} '
            'decodeMs=${stats.decodeMs} '
            'tok/s=${tps?.toStringAsFixed(2) ?? "n/a"} '
            'RSS=${mem.rssKb}kB VmHWM=${mem.hwmKb}kB',
          );
          // ignore: avoid_print
          print('[onnx android smoke] turn $turnNumber text: "$text"');
        }

        await client.shutdown().timeout(const Duration(seconds: 15));

        final finalMem = _memKb();
        // ignore: avoid_print
        print(
          '[onnx android smoke] FINAL VmHWM (peak RSS this run): '
          '${finalMem.hwmKb} kB — this is the number to record as the '
          'Android RAM floor.',
        );
        if (decodeTokPerSec.isNotEmpty) {
          final sorted = [...decodeTokPerSec]..sort();
          final median = sorted[sorted.length ~/ 2];
          // ignore: avoid_print
          print(
            '[onnx android smoke] median decode tok/s across '
            '${decodeTokPerSec.length} turns: ${median.toStringAsFixed(2)} '
            '(go >= 5, no-go < 4 — see this file\'s header)',
          );
        }
      });
    },
    // Device-gate measurement — meaningless anywhere but a real Android
    // device/emulator; skip cleanly instead of failing if this ever runs on
    // a desktop CI host by accident.
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
