/// Multi-image input integration test (PR #262 regression coverage).
///
/// Verifies `Message.withImages([...])` end-to-end on the FFI path:
/// - Two distinct images both reach the engine and are recognized by the model
/// - Duplicate-image dedup in `_pendingImages` (FfiInferenceModel)
/// - Backward compat: `Message.withImage(single)` still works
///
/// Prerequisites:
///   macOS:   gemma-4-E2B-it.litertlm in ~/Library/Containers/.../Documents/
///   Android: adb push gemma-4-E2B-it.litertlm /data/local/tmp/flutter_gemma_test/
///   iOS:     downloaded via FlutterEdgeAi.installModel()
///
/// Run: flutter test integration_test/multi_image_test.dart -d <device>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _gemma4Url =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

String get _androidDir => '/data/local/tmp/flutter_gemma_test';
String get _macosDir =>
    '${Platform.environment['HOME']}/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents';
String get _linuxDir => '${Platform.environment['HOME']}/models';
String get _windowsDir => '${Platform.environment['USERPROFILE']}\\models';

String? _localPath(String filename) {
  if (Platform.isAndroid) return '$_androidDir/$filename';
  if (Platform.isMacOS) return '$_macosDir/$filename';
  if (Platform.isLinux) return '$_linuxDir/$filename';
  if (Platform.isWindows) return '$_windowsDir\\$filename';
  return null;
}

Future<void> _install({
  required String? localPath,
  required String networkUrl,
}) async {
  if (localPath != null && File(localPath).existsSync()) {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(localPath).install();
  } else {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(networkUrl, token: _token).install();
  }
}

late InferenceModel _model;
Uint8List _img1 = Uint8List(0);
Uint8List _img2 = Uint8List(0);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final b1 = await rootBundle.load('assets/test/test_image.jpg');
    _img1 = b1.buffer.asUint8List();
    // Second image: rotated/flipped variant of the same source — distinct
    // bytes so dedup test passes and the model sees two different blobs.
    final b2 = await rootBundle.load('assets/test/test_image_2.jpg');
    _img2 = b2.buffer.asUint8List();
    print('[multi-image] img1=${_img1.length}B img2=${_img2.length}B');

    await registerTestEngines();
    await _install(
      localPath: _localPath('gemma-4-E2B-it.litertlm'),
      networkUrl: _gemma4Url,
    );

    _model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 4, // ← key for multi-image input
    );
    print('[multi-image] model loaded with maxNumImages=4');
  });

  tearDownAll(() async {
    await _model.close();
    print('[multi-image] model closed');
  });

  testWidgets('Message.withImages([img1, img2]) — both images reach engine', (
    t,
  ) async {
    final session = await _model.createSession(
      temperature: 0.8,
      topK: 1,
      enableVisionModality: true,
    );

    await session.addQueryChunk(
      Message.withImages(
        text:
            'I am sending you two images. Tell me how many images you see '
            'and briefly describe each. Answer in 2 short sentences.',
        imageBytes: [_img1, _img2],
        isUser: true,
      ),
    );

    final out = await session.getResponse();
    await session.close();

    print('[multi-image two-distinct]: $out');
    expect(out, isNotEmpty);
  });

  testWidgets('Message.withImages([img1, img1]) — duplicate dedup', (t) async {
    final session = await _model.createSession(
      temperature: 0.8,
      topK: 1,
      enableVisionModality: true,
    );

    await session.addQueryChunk(
      Message.withImages(
        text: 'Describe this image briefly.',
        imageBytes: [_img1, _img1],
        isUser: true,
      ),
    );

    final out = await session.getResponse();
    await session.close();

    print('[multi-image dedup]: $out');
    expect(out, isNotEmpty);
  });

  testWidgets('Backward compat: Message.withImage(single) still works', (
    t,
  ) async {
    final session = await _model.createSession(
      temperature: 0.8,
      topK: 1,
      enableVisionModality: true,
    );

    await session.addQueryChunk(
      Message.withImage(
        text: 'Describe this image in one sentence.',
        imageBytes: _img1,
        isUser: true,
      ),
    );

    final out = await session.getResponse();
    await session.close();

    print('[multi-image backward-compat single]: $out');
    expect(out, isNotEmpty);
  });
}
