// ONNX-GenAI real-iPhone device gate — the on-device RAM/thermal go/no-go for
// iOS arm64, the iOS analogue of `onnx_inference_smoke_test.dart` (Android FTL).
//
// Runs the SAME model/variant/prompts as every other platform's device gate so
// the tok/s numbers stay comparable, driving `GenAiFfiClient` DIRECTLY (bypasses
// `OnnxEngine.canHandle`'s host gate — the gate is the thing under measurement).
//
// Differences from the Android smoke test:
//   - `skip: !Platform.isIOS`.
//   - RSS via `ProcessInfo.currentRss`/`maxRss` (bytes) instead of
//     `/proc/self/status` — iOS has no procfs, and ProcessInfo is the
//     cross-platform kernel-backed source (maxRss = peak RSS the process has
//     hit, the number the RAM go/no-go cares about — the iOS jetsam floor).
//   - In-test HTTP download into the app's own Documents dir (a real iPhone's
//     sandbox can't read a host path, and the app requests no broad file access).
//
// Run (iPhone connected via USB, trusted):
//   cd packages/flutter_edge_ai/example
//   flutter test integration_test/onnx_ios_generation_test.dart -d <iphone-id>
import 'dart:io';

import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _repoBase =
    'https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx/resolve/'
    'main/cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4';

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

/// Temp-then-rename download; skips the network if [dest] already exists
/// non-empty (a warm app-data dir shouldn't re-pull ~2.7 GB on a re-run).
Future<void> _downloadFile(HttpClient client, String url, File dest) async {
  if (dest.existsSync() && dest.lengthSync() > 0) {
    // ignore: avoid_print
    print('[onnx ios gate] cached: ${dest.path} (${dest.lengthSync()} bytes)');
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
        print('[onnx ios gate] ${dest.uri.pathSegments.last}: $label');
      }
    }
  } finally {
    await sink.flush();
    await sink.close();
  }
  await tmp.rename(dest.path);
}

/// Current + peak RSS in kB via `dart:io`'s `ProcessInfo` (bytes → kB). Unlike
/// `/proc/self/status` this works on iOS; `maxRss` is the peak the process has
/// ever reached — the transient prefill spike the RAM go/no-go cares about.
({int rssKb, int hwmKb}) _memKb() {
  final rss = ProcessInfo.currentRss;
  final hwm = ProcessInfo.maxRss;
  if (rss <= 0 || hwm <= 0) {
    throw StateError(
      'ProcessInfo.currentRss/maxRss returned a non-positive value — refusing '
      'to report a memory measurement taken with a broken instrument',
    );
  }
  return (rssKb: rss ~/ 1024, hwmKb: hwm ~/ 1024);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ONNX GenAI iOS arm64 device gate: Phi-3.5-mini int4 through the bundled '
    'genai xcframework — functional + TTFT/decode-tok/s + RSS',
    (tester) async {
      await tester.runAsync(() async {
        final docsDir = await getApplicationDocumentsDirectory();
        final modelDir = Directory('${docsDir.path}/onnx_ios_gate_model');
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

        final configFile = File('${modelDir.path}/genai_config.json');
        expect(
          configFile.existsSync(),
          isTrue,
          reason:
              'download did not produce genai_config.json at '
              '${configFile.path}',
        );

        final beforeLoad = _memKb();
        // ignore: avoid_print
        print('[onnx ios gate] RSS before load: ${beforeLoad.rssKb} kB');

        final client = GenAiFfiClient();
        final loadSw = Stopwatch()..start();
        await client.load(modelDir.path, contextWindow: 1024);
        loadSw.stop();
        final afterLoad = _memKb();
        // ignore: avoid_print
        print(
          '[onnx ios gate] model load took ${loadSw.elapsedMilliseconds} ms '
          '(dlopen of the @executable_path-anchored genai xcframework + '
          'OgaCreateModel/OgaCreateTokenizer — the on-device proof the anchor '
          'resolves); RSS after load: ${afterLoad.rssKb} kB '
          '(delta ${afterLoad.rssKb - beforeLoad.rssKb} kB)',
        );

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
            ttftMs ??= ttftSw.elapsedMilliseconds;
            buffer.write(chunk);
          }
          final stats = client.lastGenerationStats;
          final text = buffer.toString();

          expect(
            text.trim(),
            isNotEmpty,
            reason:
                'turn $turnNumber produced no text — either generation '
                'failed silently or the genai xcframework failed to load at '
                'runtime',
          );
          expect(
            stats,
            isNotNull,
            reason: 'turn $turnNumber left no GenAiGenerationStats',
          );

          final mem = _memKb();
          final tps = stats!.tokensPerSecond;
          if (tps != null) decodeTokPerSec.add(tps);
          // ignore: avoid_print
          print(
            '[onnx ios gate] turn $turnNumber: TTFT=${ttftMs}ms '
            'prompt=${stats.promptTokens} generated=${stats.generatedTokens} '
            'decodeMs=${stats.decodeMs} '
            'tok/s=${tps?.toStringAsFixed(2) ?? "n/a"} '
            'RSS=${mem.rssKb}kB maxRss=${mem.hwmKb}kB',
          );
          // ignore: avoid_print
          print('[onnx ios gate] turn $turnNumber text: "$text"');
        }

        await client.shutdown().timeout(const Duration(seconds: 15));

        final finalMem = _memKb();
        // ignore: avoid_print
        print(
          '[onnx ios gate] FINAL maxRss (peak RSS this run): '
          '${finalMem.hwmKb} kB — the iOS RAM floor.',
        );
        if (decodeTokPerSec.isNotEmpty) {
          final sorted = [...decodeTokPerSec]..sort();
          final median = sorted[sorted.length ~/ 2];
          // ignore: avoid_print
          print(
            '[onnx ios gate] median decode tok/s across '
            '${decodeTokPerSec.length} turns: ${median.toStringAsFixed(2)} '
            '(go >= 5, no-go < 4)',
          );
        }
      });
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
