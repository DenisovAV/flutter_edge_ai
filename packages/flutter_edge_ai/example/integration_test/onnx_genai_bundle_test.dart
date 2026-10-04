// App-bundle co-location verification for the ORT-GenAI ORT_LIB_PATH fix
// (commit 330eed0a, `_exportOrtLibPath` in
// `flutter_edge_ai_onnx/lib/src/ffi/gen_ai_client.dart`).
//
// Deliberately does NOT set FLUTTER_GEMMA_ORT_GENAI_LIBS — that env var makes
// `_openGenAiLibraries` take the raw-override branch (bare dlopen of a flat
// dev directory), bypassing the exact co-location scenario this test exists
// to exercise. Running this file via
//   flutter test integration_test/onnx_genai_bundle_test.dart -d macos
// builds and runs the REAL .app bundle: both onnxruntime and
// onnxruntime-genai dylibs are staged as separate `<name>.framework`
// bundles by Flutter's Native-Assets macOS build (see `hook/build.dart`),
// and `Platform.resolvedExecutable` points inside that .app — the default
// CodeAsset lib-loading path (`libsDir == null` branch in
// `_openGenAiLibraries`).
//
// Run with: flutter test integration_test/onnx_genai_bundle_test.dart -d macos
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A real ORT-GenAI model directory (genai_config.json + .onnx[+.onnx_data]
/// + tokenizer files) — Phi-3.5-mini-instruct int4-awq, already downloaded
/// to the scratchpad by an earlier spike. Override via
/// ONNX_GENAI_BUNDLE_MODEL_DIR if it lives elsewhere.
String get _modelDir {
  final override = Platform.environment['ONNX_GENAI_BUNDLE_MODEL_DIR'];
  if (override != null && override.isNotEmpty) return override;
  const scratchpad =
      '/private/tmp/claude-501/-Users-sashadenisov-Work-1-flutter-gemma/'
      '44c8be93-6845-46c0-9448-a876536c2db2/scratchpad/ort_genai_spike/'
      'native/model/cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4';
  return scratchpad;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ORT-GenAI generates text through the bundled CodeAsset dylibs',
    (tester) async {
      final modelDir = _modelDir;
      final configFile = File('$modelDir/genai_config.json');
      if (!configFile.existsSync()) {
        fail(
          'ORT-GenAI model directory not found at $modelDir (no '
          'genai_config.json). Set ONNX_GENAI_BUNDLE_MODEL_DIR or re-download '
          'microsoft/Phi-3.5-mini-instruct-onnx '
          '(cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4).',
        );
      }

      // Sanity: the FLUTTER_GEMMA_ORT_GENAI_LIBS override MUST be unset for
      // this test to exercise the real CodeAsset co-location path. (Not
      // importing `genAiLibsDirEnvVar` itself — it isn't part of the
      // package's public barrel export — so the literal name is duplicated
      // here.)
      expect(
        Platform.environment['FLUTTER_GEMMA_ORT_GENAI_LIBS'],
        isNull,
        reason:
            'FLUTTER_GEMMA_ORT_GENAI_LIBS must not be set — this test proves '
            'the default CodeAsset bundle lib-loading path, not the raw '
            'host-test override.',
      );

      await tester.runAsync(() async {
        await FlutterEdgeAi.initialize(inferenceEngines: const [OnnxEngine()]);

        // `.fromFile(genai_config.json)` registers that exact absolute path;
        // `OnnxEngine.createModel` takes its PARENT dir as the ORT-GenAI model
        // directory (see onnx_engine.dart's `createModel` doc).
        await FlutterEdgeAi.installModel(
          modelType: ModelType.phi,
          fileType: ModelFileType.onnx,
        ).fromFile('$modelDir/genai_config.json').install();

        final model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 1024,
          preferredBackend: PreferredBackend.cpu,
        );

        try {
          final session = await model.createSession(maxOutputTokens: 16);
          try {
            await session.addQueryChunk(
              const Message(
                text: 'Say hello in one short sentence.',
                isUser: true,
              ),
            );

            final buffer = StringBuffer();
            await for (final chunk in session.getResponseAsync()) {
              buffer.write(chunk);
            }
            final responseText = buffer.toString();

            // ignore: avoid_print
            print('[onnx bundle test] generated text: "$responseText"');

            expect(
              responseText.trim(),
              isNotEmpty,
              reason:
                  'Empty response means either generation produced nothing or '
                  'the bundled genai dylib silently failed to load.',
            );
          } finally {
            await session.close();
          }
        } finally {
          await model.close();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
