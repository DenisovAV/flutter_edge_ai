// Opt-in Gemma 4 E2B memory measurement on the vivo. Stage the model at
// /data/local/tmp/flutter_gemma_test/gemma-4-E2B-it.litertlm first, then run:
// flutter test integration_test/diagnostics_model_memory_test.dart -d <device-id> --no-uninstall
//
// Each phase reports the public counters and raw smaps fields. The positive
// part of clean - (Rss - Anonymous) is a lower bound for clean anonymous pages.
// The public snapshot and the raw rollup are read at slightly different times.
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath = '/data/local/tmp/flutter_gemma_test/gemma-4-E2B-it.litertlm';

Future<void> _record(String backend, String phase) async {
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  final rollup = await File('/proc/self/smaps_rollup').readAsString();
  final fields = <String, int>{};
  for (final line in rollup.split('\n')) {
    final match = RegExp(r'^([A-Za-z_]+):\s+(\d+) kB$').firstMatch(line);
    if (match != null) {
      fields[match.group(1)!] = int.parse(match.group(2)!) * 1024;
    }
  }

  final privateClean = fields['Private_Clean']!;
  final sharedClean = fields['Shared_Clean']!;
  final rss = fields['Rss']!;
  final anonymous = fields['Anonymous']!;
  final cleanAnonymousDifference =
      privateClean + sharedClean - (rss - anonymous);

  // ignore: avoid_print
  print(
    'DIAGNOSTICS_MODEL backend=$backend phase=$phase '
    'fileBackedBytes=${snapshot.fileBackedBytes} '
    'anonymousBytes=${snapshot.anonymousBytes} '
    'availableBytes=${snapshot.availableBytes} '
    'Private_Clean=$privateClean Shared_Clean=$sharedClean '
    'Rss=$rss Anonymous=$anonymous '
    'cleanAnonymousDifference=$cleanAnonymousDifference '
    'cleanAnonymousLowerBound=${cleanAnonymousDifference > 0 ? cleanAnonymousDifference : 0}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gemma 4 E2B memory across CPU and GPU load', (tester) async {
    expect(
      Platform.isAndroid,
      isTrue,
      reason: 'This probe reads Android smaps',
    );
    expect(
      File(_modelPath).existsSync(),
      isTrue,
      reason: 'Stage Gemma 4 E2B at $_modelPath before running the probe',
    );
    await registerTestEngines();
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(_modelPath).install();

    for (final requested in [PreferredBackend.cpu, PreferredBackend.gpu]) {
      final label = requested.name;
      await _record(label, 'before_load');
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        preferredBackend: requested,
      );
      try {
        // ignore: avoid_print
        print(
          'DIAGNOSTICS_MODEL requested=$requested actual=${model.activeBackend}',
        );
        expect(model.activeBackend, requested);
        await _record(label, 'after_load');

        final session = await model.createSession(
          maxOutputTokens: 16,
          temperature: 0.8,
          topK: 1,
          enableThinking: false,
        );
        try {
          await session.addQueryChunk(
            const Message(text: 'Say hello in one word.', isUser: true),
          );
          final response = await session.getResponse();
          expect(response, isNotEmpty);
          await _record(label, 'after_first_prompt');
        } finally {
          await session.close();
        }
      } finally {
        await model.close();
      }
      await _record(label, 'after_close');
    }
  });
}
