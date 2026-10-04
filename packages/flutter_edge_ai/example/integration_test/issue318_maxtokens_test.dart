/// Issue #318 fix verification — `DYNAMIC_UPDATE_SLICE failed to prepare` /
/// `Failed to allocate tensors` when `gemma-4-E2B-it.litertlm` runs with a
/// `maxTokens` below the model's baked `kv_cache_max_len` (1024).
///
/// Root cause (reproduced end-to-end on a Pixel 8a, FTL): the crash is driven
/// solely by a too-small `maxTokens` — NOT by speculative decoding or vision
/// (both ruled out by elimination across device runs). Thresholds: 100/256/512
/// crash, 1024/4096 work. The user had set `maxTokens: 100`, conflating the
/// context window with the reply length.
///
/// This test verifies the fix:
///   - `getActiveModel(maxTokens: 100)` is auto-clamped to 1024 and answers.
///   - `createSession(maxOutputTokens: 100)` caps generation without crashing.
///
/// Run (FTL Pixel 8a / clean Android, 8 GB; .litertlm pushed via --other-files):
///   flutter test integration_test/issue318_maxtokens_test.dart -d <device>
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _gemma4Url =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

String get _androidDir => '/data/local/tmp/flutter_gemma_test';

String? _localPath(String filename) {
  if (Platform.isAndroid) return '$_androidDir/$filename';
  return null;
}

/// Install once; both cases reuse the installed identity.
Future<void> _install() async {
  final local = _localPath('gemma-4-E2B-it.litertlm');
  if (local != null && File(local).existsSync()) {
    debugPrint('[#318] installing from local file: $local');
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(local).install();
  } else {
    debugPrint('[#318] local file not found, downloading from network');
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(_gemma4Url, token: _token).install();
  }
}

/// Run a text-only prompt with the user's #318 config. The fix should make
/// `maxTokens` below 1024 auto-clamp (no crash), and `maxOutputTokens` cap the
/// generated length without touching the context window.
/// Returns (ok, response, error). Never throws — a crash is captured.
Future<({bool ok, String response, String error})> _runUserConfig({
  required int maxTokens,
  int? maxOutputTokens,
  PreferredBackend backend = PreferredBackend.cpu,
}) async {
  InferenceModel? model;
  try {
    debugPrint(
      '[#318] getActiveModel(maxTokens: $maxTokens, backend: $backend), '
      'createSession(maxOutputTokens: $maxOutputTokens)',
    );
    model = await FlutterEdgeAi.getActiveModel(
      preferredBackend: backend,
      maxTokens: maxTokens,
    );
    final session = await model.createSession(
      temperature: 0.8,
      topK: 1,
      maxOutputTokens: maxOutputTokens,
    );
    await session.addQueryChunk(
      const Message(text: 'What is the capital of France?', isUser: true),
    );
    final chunks = <String>[];
    await for (final c in session.getResponseAsync()) {
      chunks.add(c);
    }
    await session.close();
    final text = chunks.join();
    debugPrint(
      '[#318] maxTokens=$maxTokens maxOutputTokens=$maxOutputTokens '
      'OK, response="$text"',
    );
    return (ok: true, response: text, error: '');
  } catch (e) {
    debugPrint(
      '[#318] maxTokens=$maxTokens maxOutputTokens=$maxOutputTokens '
      'CRASHED: $e',
    );
    return (ok: false, response: '', error: e.toString());
  } finally {
    try {
      await model?.close();
    } catch (_) {}
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    await _install();
  });

  // FIX CHECK 1 — the user's exact crashing config: maxTokens=100. Before the
  // fix this crashed (DYNAMIC_UPDATE_SLICE). The clamp must now raise it to
  // 1024 internally so the same call generates a coherent answer.
  testWidgets(
    '#318 FIX: getActiveModel(maxTokens=100) auto-clamps and answers',
    (tester) async {
      final r = await _runUserConfig(maxTokens: 100);
      debugPrint(
        '[#318][FIX-RESULT] maxTokens=100 '
        'ok=${r.ok} response="${r.response}" error=${r.error}',
      );
      expect(
        r.ok,
        isTrue,
        reason: 'clamp should prevent the crash: ${r.error}',
      );
      expect(
        r.response.toLowerCase(),
        contains('paris'),
        reason: 'should produce a coherent answer after clamping',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  // FIX CHECK 2 — the user's real intent: limit OUTPUT length via the new
  // maxOutputTokens, leaving the context window at the default. Should answer
  // (and the cap bounds generation; we just assert it runs and is coherent).
  testWidgets(
    '#318 FIX: maxOutputTokens caps generation without crashing',
    (tester) async {
      final r = await _runUserConfig(maxTokens: 1024, maxOutputTokens: 100);
      debugPrint(
        '[#318][FIX-RESULT] maxOutputTokens=100 '
        'ok=${r.ok} response="${r.response}" error=${r.error}',
      );
      expect(
        r.ok,
        isTrue,
        reason: 'maxOutputTokens should not crash: ${r.error}',
      );
      expect(r.response.trim(), isNotEmpty, reason: 'should produce output');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  // FIX CHECK 3 — GPU coverage. The clamp runs in the engine BEFORE the
  // backend is selected, so a small maxTokens on the GPU path must also be
  // raised to 1024 and generate normally (not just CPU). Verifies the fix is
  // backend-agnostic — the DYNAMIC_UPDATE_SLICE underflow is a graph-compile
  // KV-cache resize that precedes delegate selection.
  testWidgets(
    '#318 FIX: GPU maxTokens=100 auto-clamps and answers',
    (tester) async {
      final r = await _runUserConfig(
        maxTokens: 100,
        backend: PreferredBackend.gpu,
      );
      debugPrint(
        '[#318][FIX-RESULT] GPU maxTokens=100 '
        'ok=${r.ok} response="${r.response}" error=${r.error}',
      );
      expect(
        r.ok,
        isTrue,
        reason: 'GPU clamp should prevent the crash: ${r.error}',
      );
      expect(
        r.response.toLowerCase(),
        contains('paris'),
        reason: 'GPU should produce a coherent answer after clamping',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
