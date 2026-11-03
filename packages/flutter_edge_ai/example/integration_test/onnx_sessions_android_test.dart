// ONNX independent sessions (#703) on an Android phone: two `openSession`
// sessions on one loaded Phi-3.5-mini keep separate context, the platform
// default caps open sessions at 2, and closing a session frees its slot.
//
// Reuses the model directory `onnx_inference_smoke_test.dart` downloads
// (`onnx_android_smoke_model` in the app's documents directory) — run that
// test once first on a phone that does not have it, with `--no-uninstall`
// too, or the model it downloads is deleted with the app. Drives the ORT-GenAI
// client directly, like that test, because the install layer cannot yet hand
// a whole ORT-GenAI directory to `FlutterEdgeAi.installModel`.
//
//   flutter test integration_test/onnx_sessions_android_test.dart -d <phone> \
//     --no-uninstall
//
// Prints each session's answer and the process peak RSS (VmHWM). Slow on a
// mid-range phone (Snapdragon 710: ~0.7 tok/s), a few minutes.
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — drives onnx's ORT-GenAI FFI client directly
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
// ignore: implementation_imports — reads the engine's platform default cap
import 'package:flutter_edge_ai_onnx/src/onnx_engine.dart';
// ignore: implementation_imports — builds the model over the client directly
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

String _rss() =>
    '${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0)} MiB';

int _hwmKb() {
  final line = File(
    '/proc/self/status',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('VmHWM:'));
  return int.parse(RegExp(r'(\d+)').firstMatch(line)!.group(1)!);
}

Future<String> _ask(InferenceModelSession session, String text) async {
  await session.addQueryChunk(Message(text: text, isUser: true));
  return (await session.getResponse()).toLowerCase();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'two openSession sessions keep separate context under the phone default '
    'cap of 2',
    (tester) async {
      await tester.runAsync(() async {
        final docs = await getApplicationDocumentsDirectory();
        final modelDir = '${docs.path}/onnx_android_smoke_model';
        expect(
          File('$modelDir/genai_config.json').existsSync(),
          isTrue,
          reason: 'run onnx_inference_smoke_test.dart once to download it',
        );

        expect(OnnxEngine.defaultMaxConcurrentSessions, 2);

        final client = GenAiFfiClient();
        await client.load(modelDir, contextWindow: 512);
        final model = OnnxInferenceModel(
          client: client,
          maxTokens: 512,
          modelType: ModelType.phi,
          activeBackend: null,
          maxConcurrentSessions: OnnxEngine.defaultMaxConcurrentSessions,
          onClose: () {},
        );
        addTearDown(model.close);

        // ignore: avoid_print
        print('[onnx sessions android] RSS after load ${_rss()}');
        final a = await model.openSession(topK: 1, maxOutputTokens: 8);
        final b = await model.openSession(topK: 1, maxOutputTokens: 8);
        await expectLater(model.openSession(), throwsStateError);

        await _ask(a, 'My secret word is PINEAPPLE. Reply with OK only.');
        // ignore: avoid_print
        print('[onnx sessions android] RSS after A first turn ${_rss()}');
        await _ask(b, 'My secret word is CACTUS. Reply with OK only.');
        // ignore: avoid_print
        print('[onnx sessions android] RSS after B first turn ${_rss()}');
        const q = 'What is my secret word? Answer with that one word only.';
        final a1 = await _ask(a, q);
        final b1 = await _ask(b, q);
        // ignore: avoid_print
        print(
          '[onnx sessions android] A: "$a1"  B: "$b1"  '
          'VmHWM ${_hwmKb()} kB',
        );
        expect(a1, contains('pineapple'));
        expect(a1, isNot(contains('cactus')));
        expect(b1, contains('cactus'));
        expect(b1, isNot(contains('pineapple')));

        await a.close();
        // ignore: avoid_print
        print('[onnx sessions android] RSS after A closed ${_rss()}');
        final c = await model.openSession(topK: 1, maxOutputTokens: 8);
        final c1 = await _ask(c, q);
        // ignore: avoid_print
        print(
          '[onnx sessions android] C after A closed: "$c1"  '
          'VmHWM ${_hwmKb()} kB',
        );
        expect(c1, isNot(contains('pineapple')));
        expect(c1, isNot(contains('cactus')));

        await model.close();
      });
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
