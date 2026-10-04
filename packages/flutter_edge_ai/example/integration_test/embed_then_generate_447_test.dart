// #447 as a USER sees it: embed something, then generate.
//
// The companion loader_order tests measure symbol visibility from Dart. That is
// a proxy. The failure reported in #447 is a stream that delivers ZERO chunks,
// synthesises `Exception: Stream error: <U+FFFD>` out of unread registers, and
// then aborts the process with SIGABRT when the closed NativeCallable is
// invoked again. This file reproduces THAT, or shows that it cannot be
// reproduced this way — which would mean the load-order explanation is not the
// one behind #447 and the fix has to be the native one.
//
// Order is the whole point. Our canonical suite (litertlm_ffi_test.dart) runs
// the embedding group LAST, so the failing permutation is not expressible in
// it and never has been.
//
// Needs both models pushed to the device:
//   adb push gemma-4-E2B-it.litertlm  /data/local/tmp/flutter_gemma_test/
//   adb push embeddinggemma-300M_seq256_mixed-precision.tflite  ...
//   adb push sentencepiece.model  ...
//
//   flutter test integration_test/embed_then_generate_447_test.dart -d <android>
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'loader_order_447_support.dart';

String _p(String name) => '/data/local/tmp/flutter_gemma_test/$name';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'generation still streams after embeddings loaded first',
    (t) async {
      expectLookupWorks();
      await registerTestEngines();

      // Prove the ORDER, do not assume it. If something already put
      // libLiteRtLm in the default scope, this file would report a pass while
      // exercising the permutation that always worked.
      expect(
        mappedInProcess('libLiteRtLm.so'),
        isFalse,
        reason:
            'libLiteRtLm was already mapped before the embedder ran, so this '
            'is not the embeddings-first permutation',
      );

      // ── STEP 1: embeddings FIRST. This is the step that used to decide, for
      // the whole process, whether the LLM path's stream-ABI probe could see
      // anything.
      await FlutterEdgeAi.installEmbedder()
          .modelFromFile(
            _p('embeddinggemma-300M_seq256_mixed-precision.tflite'),
          )
          .tokenizerFromFile(_p('sentencepiece.model'))
          .install();
      final embedder = await FlutterEdgeAi.getActiveEmbedder();
      final vector = await embedder.generateEmbedding('warm up the embedder');
      expect(vector, isNotEmpty, reason: 'the embedding path itself must work');
      expect(
        globallyVisible(probeSymbol),
        isTrue,
        reason:
            'the embeddings path did not leave the symbols in the default '
            'scope — the generation below would be testing nothing new',
      );
      print('[#447] embedded first: ${vector.length} dims');

      // ── STEP 2: generate. On an affected process this yields zero chunks and
      // an error synthesised from registers the caller never wrote, then aborts.
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
      print('[#447] chunks=${chunks.length} text="${chunks.join()}"');

      // Zero chunks is the reported signature, and it comes from arg 4
      // (`error_msg` <- x3, never written) reading as a non-NULL pointer,
      // which Dart treats as a failed stream. Arg 2 being a struct pointer
      // read as a C string is what corrupts the TEXT — asserted separately
      // below.
      expect(
        chunks,
        isNotEmpty,
        reason:
            'zero chunks after embedding first — the legacy callback shape was '
            'selected, which is #447',
      );
      expect(chunks.join().trim(), isNotEmpty);

      // Zero chunks is the loudest form of the failure, not the only one. The
      // legacy 4-arg shape reads args 3 and 4 from registers the caller never
      // wrote, so a partial mismatch can still deliver chunks — of garbage.
      // U+FFFD is the signature in the report.
      expect(
        chunks.join(),
        isNot(contains('\uFFFD')),
        reason:
            'the stream carried replacement characters — text decoded from '
            'something that is not text, which is the #447 corruption',
      );

      await session.close();
      await model.close();
      await embedder.close();
    },
    timeout: const Timeout(Duration(minutes: 12)),
    // skip, not fail: a whole-directory run on a Mac would otherwise show four
    // reds that are not regressions, and red you learn to ignore is worse than
    // a skip you can see.
    // Android only — the linker property under test is Android-specific.
    skip: !Platform.isAndroid,
  );
}
