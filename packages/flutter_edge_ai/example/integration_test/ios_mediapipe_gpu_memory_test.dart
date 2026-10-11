// iOS: a MediaPipe `.task` on the GPU against the app's per-process memory
// limit, with the same model as `.litertlm` through LiteRT-LM as the control.
// Backs the "iOS GPU: use .litertlm" note in website/content/docs/mediapipe.md,
// rule 8 of the flutter-edge-ai-mediapipe skill and the AGENTS.md gotcha.
//
// Measured 2026-10-10/11 on an iPhone 17 Pro, iOS 26.5.2, MediaPipe 0.10.33
// and 0.10.35, memory entitlements present:
// - gemma3-1b-it-int4.task: the footprint grows about 300 MB/s inside
//   getActiveModel up to the 6655 MB limit, and iOS kills the app. The test
//   reports "did not complete" and no crash report is written;
//   `idevicesyslog | grep memorystatus` shows `per-process-limit`.
//   waitForWeightUploads, maxTokens 2048 and sequenceBatchSize 1 change
//   nothing.
// - gemma-3n-E2B-it-int4.task: getActiveModel throws,
//   `ModifyGraphWithDelegate(gpu_delegate) == kTfLiteOk (2 vs. 0)`.
// - gemma3-1b-it-int4.litertlm: 722 MB peak while loading, 910 MB after a
//   reply.
//
// Re-run when the MediaPipe pod moves: a pass of the first test means the note
// can go. Run one test at a time, since a kill ends the whole run:
//   flutter test integration_test/ios_mediapipe_gpu_memory_test.dart \
//     -d <udid> --plain-name 'Gemma 3 1B .task'
// Copy the models into the app's Documents first (`stagedModelPath`), e.g.
//   xcrun devicectl device copy to --device <udid> --source <model> \
//     --destination Documents/ --domain-type appDataContainer \
//     --domain-identifier <bundle id>
// `flutter test` uninstalls the app, and the models with it, after a run that
// completes; a killed run leaves them in place.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

final _notIos = defaultTargetPlatform != TargetPlatform.iOS;

/// Prints the footprint, the memory still available and their sum, the
/// per-process limit.
Future<void> _mem(String tag) async {
  final m = await FlutterEdgeAiDiagnostics.memorySnapshot();
  const mb = 1024 * 1024;
  final used = (m.anonymousBytes ?? 0) ~/ mb;
  final available = (m.availableBytes ?? 0) ~/ mb;
  // ignore: avoid_print
  print(
    '[IOS-GPU-MEMORY] $tag footprint=${used}MB available=${available}MB '
    'limit=${used + available}MB',
  );
}

/// Loads [file] on the GPU, sampling memory every 2 s while it loads, then
/// asks for one reply.
Future<void> _loadOnGpu(String file, ModelFileType fileType) async {
  await registerTestEngines();
  final path = await stagedModelPath(file);
  expect(path, isNotNull, reason: 'stage $file first');
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: fileType,
  ).fromFile(path!).install();
  await _mem('$file before');
  var seconds = 0;
  final ticker = Timer.periodic(const Duration(seconds: 2), (_) {
    seconds += 2;
    unawaited(_mem('$file t+${seconds}s'));
  });
  final InferenceModel model;
  try {
    model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
    );
  } finally {
    ticker.cancel();
  }
  await _mem('$file after load');
  try {
    final session = await model.createSession();
    try {
      await session.addQueryChunk(
        const Message(text: 'Write one sentence about the sea.', isUser: true),
      );
      final reply = await session.getResponse();
      // ignore: avoid_print
      print('[IOS-GPU-MEMORY] $file reply="$reply"');
      expect(reply.trim(), isNotEmpty);
      await _mem('$file after reply');
    } finally {
      await session.close();
    }
  } finally {
    await model.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MediaPipe Gemma 3 1B .task on the iOS GPU',
    (tester) async {
      await _loadOnGpu('gemma3-1b-it-int4.task', ModelFileType.task);
    },
    skip: _notIos,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'MediaPipe Gemma 3n E2B .task on the iOS GPU',
    (tester) async {
      await _loadOnGpu('gemma-3n-E2B-it-int4.task', ModelFileType.task);
    },
    skip: _notIos,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'LiteRT-LM Gemma 3 1B .litertlm on the iOS GPU (control)',
    (tester) async {
      await _loadOnGpu('gemma3-1b-it-int4.litertlm', ModelFileType.litertlm);
    },
    skip: _notIos,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
