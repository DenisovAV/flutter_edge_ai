/// Images and audio on the web `.litertlm` path, through core: Gemma 4 E2B's
/// GPU export on @litert-lm/core 0.19.0, loaded with its vision encoder on
/// WebGPU and its audio encoder on the CPU. Measured below the packages in
/// web_litertlm_runtime_probe_test.dart (2026-11-23): an image and a clip are
/// answered; the runtime's history returns an image's bytes as
/// `blob: {bytes: [...]}`, which a preface aborts the module on, so a
/// conversation stopped after an image is rebuilt with the image as base64.
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/web_multimodal_test.dart -d web-server \
///     --dart-define=WEB_MODEL_URL=<a local copy of the GPU export>
@TestOn('chrome')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show kWebGemma4E2bUrl, registerTestEngines;

// A local copy keeps back-to-back runs off the network, e.g.
// --dart-define=WEB_MODEL_URL=http://127.0.0.1:8765/gemma-4-E2B-it-gpu.litertlm
const _webModelUrl = String.fromEnvironment(
  'WEB_MODEL_URL',
  defaultValue: kWebGemma4E2bUrl,
);

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
  return _model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 2048,
    supportImage: true,
    supportAudio: true,
  );
}

Future<Uint8List> _asset(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

/// The tests that started (Rule 6b).
final _started = <int>{};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('web .litertlm images and audio (@litert-lm/core, litertlm_dart\'s '
      'pin)', () {
    tearDownAll(() async {
      await _model?.close();
      _model = null;
    });

    testWidgets('chat: an image is answered, and the next text turn too', (
      tester,
    ) async {
      _started.add(0);
      final model = await _ensureModel();
      final image = await _asset('assets/test/test_image.jpg');
      final chat = await model.openChat(
        modelType: ModelType.gemma4,
        supportImage: true,
      );
      try {
        await chat.addQueryChunk(
          Message.withImage(
            text: 'What animal is in this image? Answer in one word.',
            imageBytes: image,
            isUser: true,
          ),
        );
        final response = await chat.generateChatResponse();

        expect(response, isA<TextResponse>(), reason: '$response');
        final text = (response as TextResponse).token.toLowerCase();
        expect(
          text,
          anyOf(contains('dog'), contains('puppy')),
          reason: 'the test picture is a black puppy (got "$text")',
        );

        await chat.addQueryChunk(
          const Message(text: 'Say hello in one word.', isUser: true),
        );
        final next = await chat.generateChatResponse();
        expect((next as TextResponse).token.trim(), isNotEmpty);
      } finally {
        await chat.close();
      }
    });

    testWidgets('session: an audio clip is answered', (tester) async {
      _started.add(1);
      final model = await _ensureModel();
      final audio = await _asset('assets/test/test_audio.wav');
      final session = await model.openSession(enableAudioModality: true);
      try {
        await session.addQueryChunk(
          Message.withAudio(
            text: 'Transcribe this audio.',
            audioBytes: audio,
            isUser: true,
          ),
        );
        final response = await session.getResponse();

        expect(response.trim(), isNotEmpty);
      } finally {
        await session.close();
      }
    });

    testWidgets('a stop after an image turn: the next message goes to the '
        'rebuilt conversation, which still holds the image', (tester) async {
      _started.add(2);
      final model = await _ensureModel();
      final image = await _asset('assets/test/test_image.jpg');
      final session = await model.openSession(enableVisionModality: true);
      try {
        // The first reply must not name the animal, or the question after
        // the stop could be answered from the text alone.
        await session.addQueryChunk(
          Message.withImage(
            text: 'Look at this image. Answer only: OK',
            imageBytes: image,
            isUser: true,
          ),
        );
        final first = (await session.getResponse()).toLowerCase();
        expect(
          first,
          isNot(anyOf(contains('dog'), contains('puppy'))),
          reason: 'the first reply named the animal: "$first"',
        );
        await session.addQueryChunk(
          const Message(
            text: 'Count from 1 to 300, one number per line.',
            isUser: true,
          ),
        );
        final stopped = Completer<void>();
        final sub = session.getResponseAsync().listen((_) async {
          if (!stopped.isCompleted) {
            stopped.complete();
            await session.stopGeneration();
          }
        }, onError: (Object _) {});
        await stopped.future;
        await sub.asFuture<void>().catchError((Object _) {});

        await session.addQueryChunk(
          const Message(
            text: 'What animal was in the image I sent? One word.',
            isUser: true,
          ),
        );
        final answer = (await session.getResponse()).toLowerCase();

        expect(
          answer,
          anyOf(contains('dog'), contains('puppy')),
          reason: 'the rebuilt conversation lost the image (got "$answer")',
        );
      } finally {
        await session.close();
      }
    });
  });

  // Rule 6b: under flutter drive a test that never ran reads as a pass.
  testWidgets('every test above started', (tester) async {
    expect(_started, hasLength(3));
  });
}
