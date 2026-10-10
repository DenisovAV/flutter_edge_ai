/// Image and audio on the web `.litertlm` path are refused with a clear error.
///
/// `@litert-lm/core` 0.18.0 creates the LLM engine with no vision or audio
/// executor: `EngineSettings.createDefault(modelAssets, backend)` takes no
/// vision or audio backend (only `EmbeddingEngine` has
/// `createDefaultMultimodal`). Measured on Gemma 4 E2B against the raw JS API
/// in Chrome 155 on Linux (WebGPU on a Tesla T4):
///   - `visionModalityEnabled` / `audioModalityEnabled: true`:
///     `createConversation` throws "Vision options should not be null." /
///     "Audio options should not be null.";
///   - a content part with the typed `data` field (base64 or bytes):
///     "Audio or image item must contain a path or blob.";
///   - the same part with the runtime's `blob` field: "Vision executor should
///     not be null, please TryLoadingVisionExecutor() first." (and the audio
///     equivalent).
/// The web session used to drop the bytes with a debug warning, and the model
/// then answered about a picture it never received. It now throws
/// [UnsupportedError] instead; these tests pin that on the real engine, and
/// that the refusal does not break the conversation that follows.
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/web_multimodal_test.dart -d web-server
@TestOn('chrome')
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _webModelUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm';

const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

InferenceModel? _model;
bool _enginesRegistered = false;

/// Everything that can fail lives in a test body, never in setUp: under
/// `flutter drive` a throwing setUp is reported as "All tests passed", because
/// integration_test only writes a result from inside `runTest`.
Future<InferenceModel> _ensureModel() async {
  if (!_enginesRegistered) {
    await registerTestEngines();
    _enginesRegistered = true;
  }
  if (_model != null) return _model!;
  await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      )
      .fromNetwork(_webModelUrl, token: _hfToken.isEmpty ? null : _hfToken)
      .install();
  return _model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

Future<Uint8List> _asset(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

Matcher _refused(String kind) => throwsA(
  isA<UnsupportedError>().having(
    (e) => e.message,
    'message',
    contains('Web LiteRT-LM does not support $kind input for LLMs yet'),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('web .litertlm image/audio (@litert-lm/core 0.18.0)', () {
    tearDownAll(() async {
      await _model?.close();
      _model = null;
    });

    testWidgets('chat: an image throws, and the chat still answers text', (
      tester,
    ) async {
      final model = await _ensureModel();
      final image = await _asset('assets/test/test_image.jpg');
      // supportImage: true is what a cross-platform app passes; the chat must
      // still open, because a text-only conversation is valid on web.
      final chat = await model.createChat(
        modelType: ModelType.gemma4,
        supportImage: true,
      );
      try {
        await expectLater(
          chat.addQueryChunk(
            Message.withImage(
              text: 'What animal is in this image? Answer in one word.',
              imageBytes: image,
              isUser: true,
            ),
          ),
          _refused('image'),
        );

        await chat.addQueryChunk(
          const Message(text: 'Say hello in one word.', isUser: true),
        );
        final response = await chat.generateChatResponse();
        expect(response, isA<TextResponse>(), reason: '$response');
        final text = (response as TextResponse).token;
        expect(text.trim(), isNotEmpty);
        expect(
          text.toLowerCase(),
          isNot(anyOf(contains('dog'), contains('puppy'))),
          reason:
              'the refused image must not reach the model (got "$text"); the '
              'test picture is a black puppy',
        );
      } finally {
        await chat.close();
      }
    });

    testWidgets('session: audio throws, and the session still answers text', (
      tester,
    ) async {
      final model = await _ensureModel();
      final audio = await _asset('assets/test/test_audio.wav');
      final session = await model.createSession(enableAudioModality: true);
      try {
        await expectLater(
          session.addQueryChunk(
            Message.withAudio(
              text: 'Transcribe this audio.',
              audioBytes: audio,
              isUser: true,
            ),
          ),
          _refused('audio'),
        );

        await session.addQueryChunk(
          const Message(text: 'Say goodbye in one word.', isUser: true),
        );
        final response = await session.getResponse();
        expect(response.trim(), isNotEmpty);
      } finally {
        await session.close();
      }
    });
  });
}
