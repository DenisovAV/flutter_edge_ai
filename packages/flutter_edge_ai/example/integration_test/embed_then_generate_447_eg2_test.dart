// #447 with EmbeddingGemma 2 (R5 §10.1): embed with the `.litertlm` pass
// FIRST, then generate.
//
// embed_then_generate_447_test.dart covers the `.tflite` embedder, which
// reaches libLiteRtLm through LiteRtBindings. The EmbeddingGemma 2 pass opens
// it through litert_lm_library.dart instead, from core's embedding worker
// isolate — a different first opener, so the same question again: whoever
// opens libLiteRtLm first decides, for the whole process, whether the LLM
// path's stream-ABI probe can see its exports. If it cannot, generation
// streams zero chunks (or garbage) and then aborts.
//
// Its own file, because the order only holds in a fresh process.
//
// Needs Gemma 4 E2B pushed to the device; the EG2 bundle is taken from the
// same directory when pushed there, else downloaded (ungated, pinned):
//   adb push gemma-4-E2B-it.litertlm  /data/local/tmp/flutter_gemma_test/
//   adb push embeddinggemma-2-text-270m.litertlm  /data/local/tmp/flutter_gemma_test/
//
//   flutter test integration_test/embed_then_generate_447_eg2_test.dart -d <android>
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'loader_order_447_support.dart';

String _p(String name) => '/data/local/tmp/flutter_gemma_test/$name';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'generation still streams after the EmbeddingGemma 2 pass loaded first',
    (t) async {
      expectLookupWorks();
      await registerTestEngines();

      // Prove the ORDER, do not assume it. The maps check is the one the
      // .tflite #447 suite uses; it only sees a library extracted to the lib
      // dir (see mappedInProcess). The control symbol adds what it misses: an
      // earlier opener that already put libLiteRtLm in the default scope
      // would make this run test nothing.
      expect(
        mappedInProcess('libLiteRtLm.so'),
        isFalse,
        reason:
            'libLiteRtLm was already mapped before the embedder ran, so this '
            'is not the embeddings-first permutation',
      );
      expect(
        globallyVisible(controlSymbol),
        isFalse,
        reason:
            'libLiteRtLm was already in the default scope before the embedder '
            'ran, so this is not the embeddings-first permutation',
      );

      // ── STEP 1: the .litertlm embedder FIRST.
      final pushed = File(_p('embeddinggemma-2-text-270m.litertlm'));
      final builder = FlutterEdgeAi.installEmbedder();
      if (pushed.existsSync()) {
        builder.modelFromFile(pushed.path, filename: _eg2.filename);
      } else {
        builder.modelFromNetwork(_eg2.url, filename: _eg2.filename);
      }
      await builder.install();
      final embedder = await FlutterEdgeAi.getActiveEmbedder();
      final vector = await embedder.embed(
        EmbeddingInput.text('warm up the embedder'),
        taskType: TaskType.retrievalQuery,
      );
      expect(vector, hasLength(768), reason: 'the EG2 path itself must work');
      // The EG2 pass loaded libLiteRtLm, into the default scope. Not asked of
      // /proc/self/maps: this APK stores the .so uncompressed and bionic maps
      // it straight out of base.apk, so the maps name base.apk, never
      // libLiteRtLm.so (FTL, Pixel 8a / 8 Pro: the pass had embedded, and
      // the maps check said "not mapped"). dlsym(RTLD_DEFAULT) answers only
      // for an export of a library that is loaded AND global, and
      // litert_lm_engine_create exists only in libLiteRtLm — so this says
      // more than "mapped", whatever the packaging.
      expect(
        globallyVisible(controlSymbol),
        isTrue,
        reason:
            'after the EG2 pass ran, libLiteRtLm is not loaded into the '
            'default scope',
      );
      expect(
        globallyVisible(probeSymbol),
        isTrue,
        reason:
            'the EG2 pass did not leave libLiteRtLm\'s symbols in the default '
            'scope — the generation below would fail as #447 did',
      );
      // ignore: avoid_print
      print('[#447/eg2] embedded first: ${vector.length} dims');

      // ── STEP 2: generate.
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_p('gemma-4-E2B-it.litertlm')).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));

      final chunks = <String>[];
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
      }
      // ignore: avoid_print
      print('[#447/eg2] chunks=${chunks.length} text="${chunks.join()}"');

      expect(
        chunks,
        isNotEmpty,
        reason:
            'zero chunks after the EG2 embedder ran first — the legacy '
            'callback shape was selected, which is #447',
      );
      expect(chunks.join().trim(), isNotEmpty);
      expect(
        chunks.join(),
        isNot(contains('�')),
        reason: 'the stream carried replacement characters — #447 corruption',
      );

      await session.close();
      await model.close();
      await embedder.close();
    },
    timeout: const Timeout(Duration(minutes: 15)),
    // Android only — the linker property under test is Android-specific.
    skip: !Platform.isAndroid,
  );
}
