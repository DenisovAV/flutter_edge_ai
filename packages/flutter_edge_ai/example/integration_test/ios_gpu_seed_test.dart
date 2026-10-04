// iPhone GPU sampler params verification (Strategy D + new Google dylibs).
//
// Verifies that randomSeed and temperature are honored end-to-end on
// iPhone Metal GPU sampler. Uses Gemma3-1B (already on device after
// ios_01_gpu_gemma3_1b.dart) so no 2.4GB Gemma4 download.
//
// Logic:
//   - Two runs at temperature=1.0 with same seed (42, 42) → must be IDENTICAL
//   - Run with seed=99 vs seed=42 → must be DIFFERENT
// If either fails, sampler params are dropped and Strategy D / new dylibs
// are not honoring session-level seed.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS GPU: Gemma3-1B honors randomSeed + temperature',
    (t) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
            modelType: ModelType.gemmaIt,
            fileType: ModelFileType.litertlm,
          )
          .fromNetwork(
            _url,
            token: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
          )
          .install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.gpu,
      );

      Future<String> runOnce(int seed) async {
        final session = await model.createSession(
          temperature: 1.0,
          topK: 50,
          topP: 0.95,
          randomSeed: seed,
        );
        await session.addQueryChunk(
          const Message(
            text: 'Write a 30-word creative story about a dragon.',
            isUser: true,
          ),
        );
        final out = await session.getResponse();
        await session.close();
        return out;
      }

      final seed42a = await runOnce(42);
      print('[GPU seed=42 #A]\n$seed42a\n');
      final seed42b = await runOnce(42);
      print('[GPU seed=42 #B]\n$seed42b\n');
      final seed99 = await runOnce(99);
      print('[GPU seed=99]\n$seed99\n');

      expect(
        seed42a,
        equals(seed42b),
        reason:
            'Same seed (42) twice must yield identical output. '
            'Different = sampler params dropped.\n'
            'A=$seed42a\nB=$seed42b',
      );

      expect(
        seed42a,
        isNot(equals(seed99)),
        reason:
            'Different seeds (42 vs 99) must yield different output. '
            'Identical = sampler ignores seed.\n'
            'seed42=$seed42a\nseed99=$seed99',
      );

      await model.close();
      print('iOS GPU SAMPLER PARAMS PASSED');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
