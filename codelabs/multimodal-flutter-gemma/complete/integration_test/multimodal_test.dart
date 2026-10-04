// End-to-end check of a multimodal turn on a real device or desktop.
//
// Downloads Gemma 4 E2B (2.59 GB, ungated — no Hugging Face token), opens ONE
// session with both modality flags set to whatever this platform allows, and
// sends an image through it. The claim under test is the codelab's thesis: a
// modality is a session flag on the same weights, and the flags the app sets
// are the ones the platform agreed to.
//
// Not part of CI (needs a device and a 2.59 GB download):
//   flutter test integration_test/multimodal_test.dart -d <device-id>
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/capabilities.dart';
import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/wav.dart';

/// A 16x16 solid-red PNG, inline so the suite needs no asset bundle.
final _redSquarePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mN4oKBA'
  'EmIY1TCqYfhqAADc5yAQocSb7AAAAABJRU5ErkJggg==',
);

/// Downloads the model if it is not here, and makes it the active one either
/// way. `install()` is idempotent, so a second run costs nothing.
Future<void> _install(ModelChoice model) async {
  var last = -1;
  await FlutterEdgeAi.installModel(
    modelType: model.modelType,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(model.url).withProgress((p) {
    if (p >= last + 25) {
      last = p;
      debugPrint('[multimodal] download $p%');
    }
  }).install();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one model, one session, both flags the platform allows', (
    tester,
  ) async {
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

    const model = Models.gemma4;
    final image = imageCapability(model);
    final audio = audioCapability(model);
    debugPrint(
      '[multimodal] image — model: ${image.byModel}, '
      'platform: ${image.byPlatform}',
    );
    debugPrint(
      '[multimodal] audio — model: ${audio.byModel}, '
      'platform: ${audio.byPlatform}',
    );

    // The model half is yes for both on this checkpoint, everywhere. Anything
    // else means the flags on `Models.gemma4` drifted from the weights.
    expect(image.byModel, isTrue);
    expect(audio.byModel, isTrue);

    await _install(model);
    expect(await FlutterEdgeAi.isModelInstalled(model.fileName), isTrue);

    // The flags go here too — this is where the engine loads (or does not
    // load) the vision and audio executors. Measured: with them only on the
    // chat, the first image fails the turn with
    // `INVALID_ARGUMENT: Vision executor should not be null`.
    final inference = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      supportImage: image.available,
      supportAudio: audio.available,
    );
    // Exactly what the app opens: both flags, each ANDed with the platform.
    final chat = await inference.createChat(
      modelType: model.modelType,
      supportImage: image.available,
      supportAudio: audio.available,
      maxOutputTokens: 64,
    );

    if (image.available) {
      await chat.addQueryChunk(
        Message.withImages(
          text: 'What colour is this image? Answer in one word.',
          imageBytes: [_redSquarePng],
          isUser: true,
        ),
      );
    } else {
      // Nothing to prove about pixels here; say so, and check the same session
      // still answers in text.
      debugPrint('[multimodal] image SKIPPED: ${image.blockedBecause}');
      await chat.addQueryChunk(
        Message.text(text: 'Name one colour. One word.', isUser: true),
      );
    }

    final buffer = StringBuffer();
    await for (final chunk in chat.generateChatResponseAsync()) {
      if (chunk is TextResponse) buffer.write(chunk.token);
    }
    final reply = buffer.toString().trim();
    debugPrint('[multimodal] reply: $reply');
    if (image.available) {
      // `isNotEmpty` would not distinguish "the picture reached the weights"
      // from "the bytes were dropped and the model answered from the text
      // alone" — `ffi_inference_model.dart` gates the image on the session
      // flag and discards it in silence when the flag is false, which is
      // exactly the inverse of the bug this suite exists to catch. The turn
      // has ground truth, so use it: measured, this answers "Red".
      expect(reply.toLowerCase(), contains('red'));
    } else {
      expect(reply, isNotEmpty);
    }

    // The codelab's headline: the SAME session, the same weights, now given
    // sound. One second of silence is enough — what is under test is that the
    // audio modality was accepted, not what the model heard in it.
    if (audio.available) {
      await chat.addQueryChunk(
        Message.withAudio(
          text: 'Describe this audio in one word.',
          audioBytes: wavFromPcm16(
            Uint8List(32000),
            sampleRate: 16000,
            channels: 1,
          ),
          isUser: true,
        ),
      );
      final heard = StringBuffer();
      await for (final chunk in chat.generateChatResponseAsync()) {
        if (chunk is TextResponse) heard.write(chunk.token);
      }
      debugPrint('[multimodal] audio reply: ${heard.toString().trim()}');
      expect(heard.toString().trim(), isNotEmpty);
    } else {
      debugPrint('[multimodal] audio SKIPPED: ${audio.blockedBecause}');
    }

    await inference.close();
  }, timeout: const Timeout(Duration(minutes: 60)));

  test('the WAV header the recorder produces is the one the model expects', () {
    final wav = wavFromPcm16(Uint8List(3200), sampleRate: 16000, channels: 1);
    expect(wav.length, 3244);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');

    // A stream cut mid-sample must not produce a header that promises a byte
    // the data does not have: the half sample is dropped, not counted.
    final odd = wavFromPcm16(Uint8List(3201), sampleRate: 16000, channels: 1);
    expect(odd.length, 3244);
  });
}
