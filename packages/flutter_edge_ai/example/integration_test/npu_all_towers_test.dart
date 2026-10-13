// Gemma 4 E2B bundles with every modality compiled for the Qualcomm NPU
// (Google, 2026-10-12): does the package run the vision and audio encoders on
// the Hexagon when the app asks for it, and what does that buy?
//
// One process, two loads of the same bundle: encoders on the NPU, then on the
// CPU (the package default for encoders). Each load answers a text prompt (the
// baseline), an image prompt and an audio prompt; the time to the first token
// of a media prompt minus the text baseline is the encoder's share.
//
// No setUp/setUpAll: everything that can fail runs inside the test body.
//
// Run (Linux board):
//   flutter test integration_test/npu_all_towers_test.dart -d linux \
//     --dart-define=NPU_MEDIA_MODEL=$HOME/models/<bundle>.litertlm
// Run (Android, pushed to /data/local/tmp/flutter_gemma_test): same define.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath = String.fromEnvironment('NPU_MEDIA_MODEL');

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<({Duration firstToken, Duration total, String text})> _ask(
  InferenceModel model,
  Message message, {
  bool vision = false,
  bool audio = false,
}) async {
  final session = await model.createSession(
    enableVisionModality: vision,
    enableAudioModality: audio,
    maxOutputTokens: 64,
  );
  try {
    await session.addQueryChunk(message);
    final sw = Stopwatch()..start();
    Duration? first;
    final out = StringBuffer();
    await for (final chunk in session.getResponseAsync()) {
      first ??= sw.elapsed;
      out.write(chunk);
    }
    return (
      firstToken: first ?? sw.elapsed,
      total: sw.elapsed,
      text: out.toString().trim(),
    );
  } finally {
    await session.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gemma 4 E2B: encoders on the NPU vs on the CPU', (t) async {
    if (_modelPath.isEmpty || !File(_modelPath).existsSync()) {
      fail('NPU_MEDIA_MODEL is unset or missing: "$_modelPath"');
    }
    await registerTestEngines();
    final image = await _asset('assets/test/test_image.jpg');
    final audio = await _asset('assets/test/test_audio.wav');
    print(
      '[towers] model=$_modelPath image=${image.length}B '
      'audio=${audio.length}B',
    );

    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(_modelPath).install();

    final failures = <String>[];
    for (final towers in [PreferredBackend.npu, PreferredBackend.cpu]) {
      final tag = '[towers=${towers.name}]';
      final InferenceModel model;
      final loadSw = Stopwatch()..start();
      try {
        model = await FlutterEdgeAi.getActiveModel(
          maxTokens: 1024,
          preferredBackend: PreferredBackend.npu,
          preferredVisionBackend: towers,
          preferredAudioBackend: towers,
          supportImage: true,
          supportAudio: true,
        );
      } catch (e) {
        print('$tag LOAD FAILED after ${loadSw.elapsedMilliseconds} ms: $e');
        failures.add('$tag load: $e');
        continue;
      }
      try {
        print(
          '$tag loaded in ${loadSw.elapsedMilliseconds} ms, '
          'activeBackend=${model.activeBackend}',
        );
        final text = await _ask(
          model,
          const Message(text: 'Name one colour. One word.', isUser: true),
        );
        final img = await _ask(
          model,
          Message(
            text: 'Describe this image in one sentence.',
            isUser: true,
            imageBytes: image,
          ),
          vision: true,
        );
        final aud = await _ask(
          model,
          Message(
            text: 'Transcribe this audio.',
            isUser: true,
            audioBytes: audio,
          ),
          audio: true,
        );
        String row(
          String name,
          ({Duration firstToken, Duration total, String text}) r,
        ) =>
            '$tag $name: first token ${r.firstToken.inMilliseconds} ms '
            '(encoder share ~${(r.firstToken - text.firstToken).inMilliseconds} ms), '
            'total ${r.total.inMilliseconds} ms: "${r.text}"';
        print(
          '$tag text: first token ${text.firstToken.inMilliseconds} ms: '
          '"${text.text}"',
        );
        print(row('image', img));
        print(row('audio', aud));
        if (img.text.isEmpty) failures.add('$tag image: empty answer');
        if (aud.text.isEmpty) failures.add('$tag audio: empty answer');
      } catch (e) {
        print('$tag RUN FAILED: $e');
        failures.add('$tag run: $e');
      } finally {
        await model.close();
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
