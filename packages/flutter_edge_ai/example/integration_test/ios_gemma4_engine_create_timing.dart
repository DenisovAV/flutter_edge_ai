// Reproduce eav-solution's exact configuration from #245 to measure
// engine_create timing on iPhone for Gemma 4 E2B GPU with multimodal support.
//
// User config (from #245 comment 2026-05-01):
//   modelType: ModelType.gemmaIt
//   fileType: ModelFileType.litertlm
//   getActiveModel: maxTokens: 2048, supportAudio: true, supportImage: true,
//                   preferredBackend: PreferredBackend.gpu
//   model.createChat(...)
//
// Goal: confirm / refute that supportImage+supportAudio (multimodal init) is
// the cause of the reported 3-5 minute load time. Baseline (text-only,
// supportImage:false supportAudio:false) was 7.0 s on iPhone 16 Pro.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS: Gemma 4 E2B GPU multimodal timing (eav-solution #245 config)',
    (t) async {
      await registerTestEngines();

      final installStart = DateTime.now();
      await FlutterEdgeAi.installModel(
            modelType: ModelType.gemmaIt, // user uses gemmaIt, not gemma4
            fileType: ModelFileType.litertlm,
          )
          .fromNetwork(
            _url,
            token: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
          )
          .install();
      final installMs = DateTime.now().difference(installStart).inMilliseconds;
      print('[TIMING] installModel: ${installMs}ms');

      final modelStart = DateTime.now();
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048, // user value (we used 4096 before)
        supportAudio: true, // user enables audio
        supportImage: true, // user enables vision
        preferredBackend: PreferredBackend.gpu,
      );
      final modelMs = DateTime.now().difference(modelStart).inMilliseconds;
      print('[TIMING] getActiveModel (engine_create): ${modelMs}ms');

      // User uses createChat, not createSession
      final chatStart = DateTime.now();
      final chat = await model.createChat();
      final chatMs = DateTime.now().difference(chatStart).inMilliseconds;
      print('[TIMING] createChat: ${chatMs}ms');

      final promptStart = DateTime.now();
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      final response = await chat.generateChatResponse();
      final promptMs = DateTime.now().difference(promptStart).inMilliseconds;
      print('[TIMING] first response (prefill+decode): ${promptMs}ms');
      print('[OUTPUT] $response');

      print('---');
      print('[TIMING SUMMARY — eav-solution config]');
      print('  installModel:     ${installMs}ms');
      print('  engine_create:    ${modelMs}ms (was 7032ms text-only baseline)');
      print('  createChat:       ${chatMs}ms');
      print('  first response:   ${promptMs}ms');
      print('---');
      print('Comparison vs baseline:');
      print('  baseline (text-only, maxTokens=4096): engine_create=7032ms');
      print(
        '  current (multimodal, maxTokens=2048): engine_create=${modelMs}ms',
      );
      print(
        '  delta: ${modelMs - 7032}ms (${((modelMs - 7032) / 7032 * 100).toStringAsFixed(0)}%)',
      );
      print('---');

      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
