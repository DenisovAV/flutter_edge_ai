/// MediaPipe `.task` multi-session integration test (#226).
///
/// Verifies concurrent openSession() on the MediaPipe engine: two sessions
/// keep isolated history (each is a real native LlmInferenceSession), closing
/// one leaves the other usable, and the legacy createSession() singleton still
/// works afterwards. Generation is serialized (a Dart Mutex) — concurrent
/// contexts, serialized inference, same model as the .litertlm FFI path.
///
/// Model: gemma3-1b-it-int4.task (small, instruction-tuned, recalls a name).
/// Push first: adb push gemma3-1b-it-int4.task /data/local/tmp/flutter_gemma_test/
///
/// Run:
///   Android: cd example && flutter test integration_test/multi_session_mediapipe_test.dart -d <android-id>
///   iOS:     cd example && flutter test integration_test/multi_session_mediapipe_test.dart -d <ios-id>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _androidDir = '/data/local/tmp/flutter_gemma_test';
const _taskFilename = 'gemma3-1b-it-int4.task';

Future<String> _localTaskPath() async {
  if (Platform.isIOS) {
    // iOS Simulator can read the host macOS filesystem — pass the host dir
    // holding the .task via --dart-define=IOS_TEST_DOCS_DIR=... so the model
    // survives the simulator's ephemeral app sandbox (same trick as
    // litertlm_ffi_test.dart). Falls back to the app Documents on device.
    const hostDir = String.fromEnvironment('IOS_TEST_DOCS_DIR');
    if (hostDir.isNotEmpty) {
      final p = '$hostDir/$_taskFilename';
      if (File(p).existsSync()) return p;
    }
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_taskFilename';
  }
  return '$_androidDir/$_taskFilename';
}

Future<void> _install() async {
  final local = await _localTaskPath();
  if (File(local).existsSync()) {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.task,
    ).fromFile(local).install();
  } else {
    fail(
      'MediaPipe .task model not found at $local. Push $_taskFilename to '
      '$_androidDir (Android) or copy it into the app Documents (iOS).',
    );
  }
}

Future<String> _ask(InferenceModelSession s, String prompt) async {
  await s.addQueryChunk(Message(text: prompt, isUser: true));
  return s.getResponse();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('MediaPipe .task multi-session (#226)', () {
    setUpAll(() async {
      await registerTestEngines();
      await _install();
    });

    testWidgets(
      'two openSession dialogues keep isolated history',
      (t) async {
        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
          preferredBackend: PreferredBackend.cpu,
        );
        final a = await model.openSession(temperature: 0.0, topK: 1);
        final b = await model.openSession(temperature: 0.0, topK: 1);
        try {
          expect(model.sessions.length, greaterThanOrEqualTo(2));

          await _ask(a, 'My name is Alice. Remember it.');
          await _ask(b, 'My name is Bob. Remember it.');

          final ra = (await _ask(
            a,
            'What is my name? One word.',
          )).toLowerCase();
          final rb = (await _ask(
            b,
            'What is my name? One word.',
          )).toLowerCase();
          // ignore: avoid_print
          print('[mp multi-session] A="$ra" B="$rb"');

          expect(ra, contains('alice'), reason: 'A should recall Alice');
          expect(
            ra,
            isNot(contains('bob')),
            reason: 'A must not see B history',
          );
          expect(rb, contains('bob'), reason: 'B should recall Bob');
          expect(
            rb,
            isNot(contains('alice')),
            reason: 'B must not see A history',
          );
        } finally {
          await a.close();
          await b.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'closing one session leaves the other usable',
      (t) async {
        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
          preferredBackend: PreferredBackend.cpu,
        );
        final a = await model.openSession(temperature: 0.0, topK: 1);
        final b = await model.openSession(temperature: 0.0, topK: 1);
        await a.close();
        final rb = await _ask(b, 'Say hi in one word.');
        // ignore: avoid_print
        print('[mp multi-session S2] B after A.close = "$rb"');
        expect(rb.trim(), isNotEmpty);
        await b.close();
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'legacy createSession still works after openSession',
      (t) async {
        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 512,
          preferredBackend: PreferredBackend.cpu,
        );
        // openSession then close it; the legacy singleton lane must be unaffected.
        final open = await model.openSession(temperature: 0.0, topK: 1);
        await open.close();

        final legacy = await model.createSession(temperature: 0.0, topK: 1);
        final r = await _ask(legacy, 'Say hello in one word.');
        // ignore: avoid_print
        print('[mp legacy after open] "$r"');
        expect(r.trim(), isNotEmpty);
        await legacy.close();
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
