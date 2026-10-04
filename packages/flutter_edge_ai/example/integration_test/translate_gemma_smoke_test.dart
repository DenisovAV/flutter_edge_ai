// 0.15.3 TranslateGemma 4B smoke test.
//
// Exercises `TranslateRunner` end-to-end on the community `.litertlm` int4
// bundle. The test:
//   1. Stages the int4 `.litertlm` from the app's documents dir (~2 GB —
//      see pre-staging notes below).
//   2. Installs it via `FlutterEdgeAi.installModel(...).fromFile(...)`.
//   3. Builds a `TranslateRunner` using the same XML strategy the example
//      app uses.
//   4. Runs three language pairs (en→fr, en→es, ja→en) and asserts the
//      output is non-empty and contains expected keywords.
//
// Pre-stage the model file in the platform sandbox before running:
//   macOS:   ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/
//   Android: adb push <file> /data/data/dev.flutterberlin.flutter_gemma_example/app_flutter/
// On both platforms `getApplicationDocumentsDirectory()` resolves to that
// location, so the test reads it via `fromFile()`.

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_edge_ai_example/translation/translate_gemma_xml_strategy.dart';
import 'package:flutter_edge_ai_example/translation/translate_runner.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelName = 'translategemma-4b-it-int4-generic.litertlm';

/// Resolve a file path in the app documents directory. If absent, copy
/// from the bundled `assets/test/<name>` (works on every platform).
Future<String> _docsPath(String name) async {
  final docs = await getApplicationDocumentsDirectory();
  final f = File('${docs.path}/$name');
  if (f.existsSync()) return f.path;
  final bytes = await rootBundle.load('assets/test/$name');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  return f.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TranslateGemma 4B int4 — translate three language pairs',
    (_) async {
      await registerTestEngines();

      final modelPath = await _docsPath(_modelName);

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        // On GPU this bundle loads and then answers with nothing but
        // <pad> — see translate_model.dart + LiteRT-LM#1748.
        preferredBackend: PreferredBackend.cpu,
      );

      try {
        final runner = TranslateRunner(
          model: model,
          strategy: const TranslateGemmaXmlPromptStrategy(),
        );

        // en → fr
        final fr = await runner.translate(
          text: 'Hello world',
          src: 'en',
          dst: 'fr',
        );
        print('[TranslateGemma] en→fr: $fr');
        expect(fr.trim(), isNotEmpty);
        expect(fr.toLowerCase(), contains('bonjour'));

        // en → es
        final es = await runner.translate(
          text: 'Good morning',
          src: 'en',
          dst: 'es',
        );
        print('[TranslateGemma] en→es: $es');
        expect(es.trim(), isNotEmpty);
        expect(
          es.toLowerCase(),
          anyOf(contains('buenos'), contains('buen día')),
        );

        // ja → en
        final enFromJa = await runner.translate(
          text: 'ありがとうございます',
          src: 'ja',
          dst: 'en',
        );
        print('[TranslateGemma] ja→en: $enFromJa');
        expect(enFromJa.trim(), isNotEmpty);
        expect(enFromJa.toLowerCase(), contains('thank'));
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'TranslateGemma 4B int4 — streaming yields chunks',
    (_) async {
      await registerTestEngines();

      final modelPath = await _docsPath(_modelName);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        // On GPU this bundle loads and then answers with nothing but
        // <pad> — see translate_model.dart + LiteRT-LM#1748.
        preferredBackend: PreferredBackend.cpu,
      );

      try {
        final runner = TranslateRunner(
          model: model,
          strategy: const TranslateGemmaXmlPromptStrategy(),
        );

        final chunks = <String>[];
        await for (final c in runner.translateStream(
          text: 'The quick brown fox jumps over the lazy dog',
          src: 'en',
          dst: 'fr',
        )) {
          chunks.add(c);
        }

        final full = chunks.join();
        print('[TranslateGemma stream] ${chunks.length} chunks → "$full"');
        expect(chunks, isNotEmpty);
        expect(full.trim(), isNotEmpty);
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
