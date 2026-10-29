// Gemma 4 E2B with the text model on the Qualcomm NPU: which backend should
// the vision and audio encoders ("towers") run on?
//
// One process, one load per variant. A variant is `<vision>-<audio>`, each
// `unset` (the package default), `cpu`, `gpu` or `npu`. Each load answers a
// text prompt (the baseline), then an image and an audio prompt twice (cold,
// warm); the time to the first token of a media prompt minus the text
// baseline is the encoder's share. A variant that fails to load or to answer
// is reported, not fatal: this is a measurement. Only `unset-unset` must work.
// `npu` for an encoder the bundle does not compile for the NPU (the public
// Qualcomm bundles) is refused before the load, so it is not in the defaults.
//
// No setUp/setUpAll: everything that can fail runs inside the test body.
//
// Run (Android, the phone downloads the bundle itself):
//   --dart-define=NPU_MEDIA_URL=https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_qualcomm_sm8750.litertlm
//   --dart-define=NPU_TOWERS=unset-unset,cpu-cpu,gpu-cpu,gpu-gpu
// or NPU_MEDIA_MODEL=<path> for a bundle already on the device.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelUrl = String.fromEnvironment('NPU_MEDIA_URL');
const _modelPath = String.fromEnvironment('NPU_MEDIA_MODEL');
const _towers = String.fromEnvironment(
  'NPU_TOWERS',
  defaultValue: 'unset-unset,cpu-cpu,gpu-cpu,gpu-gpu',
);
const _maxTokens = int.fromEnvironment('NPU_MAX_TOKENS', defaultValue: 1024);

typedef _Answer = ({Duration firstToken, Duration total, String text});

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

PreferredBackend? _backend(String name) => switch (name) {
  'unset' => null,
  'cpu' => PreferredBackend.cpu,
  'gpu' => PreferredBackend.gpu,
  'npu' => PreferredBackend.npu,
  _ => throw ArgumentError('unknown tower backend "$name"'),
};

Future<_Answer> _ask(
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
      text: out.toString().trim().replaceAll('\n', ' '),
    );
  } finally {
    await session.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gemma 4 E2B on the NPU: tower backend matrix', (t) async {
    await registerTestEngines();
    final image = await _asset('assets/test/test_image.jpg');
    final audio = await _asset('assets/test/test_audio.wav');

    final installSw = Stopwatch()..start();
    if (_modelPath.isNotEmpty) {
      if (!File(_modelPath).existsSync()) fail('missing: $_modelPath');
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(_modelPath).install();
    } else if (_modelUrl.isNotEmpty) {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_modelUrl).install();
    } else {
      fail('set NPU_MEDIA_URL or NPU_MEDIA_MODEL');
    }
    print(
      '[matrix] model=${_modelPath.isNotEmpty ? _modelPath : _modelUrl} '
      'installed in ${installSw.elapsed.inSeconds} s, maxTokens=$_maxTokens, '
      'variants=$_towers',
    );

    final summary = <String>[];
    var defaultWorked = false;
    for (final variant in _towers.split(',').map((s) => s.trim())) {
      final parts = variant.split('-');
      final vision = _backend(parts[0]);
      final audioBackend = _backend(parts[1]);
      final tag = '[matrix $variant]';
      final loadSw = Stopwatch()..start();
      final InferenceModel model;
      try {
        model = await FlutterEdgeAi.getActiveModel(
          maxTokens: _maxTokens,
          preferredBackend: PreferredBackend.npu,
          preferredVisionBackend: vision,
          preferredAudioBackend: audioBackend,
          supportImage: true,
          supportAudio: true,
        );
      } catch (e) {
        final line =
            '$tag LOAD FAILED after ${loadSw.elapsedMilliseconds} ms: $e';
        print(line);
        summary.add(line);
        continue;
      }
      final load = loadSw.elapsedMilliseconds;
      try {
        print('$tag loaded in $load ms, activeBackend=${model.activeBackend}');
        final text = await _ask(
          model,
          const Message(text: 'Name one colour. One word.', isUser: true),
        );
        final imageMessage = Message(
          text: 'Describe this image in one sentence.',
          isUser: true,
          imageBytes: image,
        );
        final audioMessage = Message(
          text: 'Transcribe this audio.',
          isUser: true,
          audioBytes: audio,
        );
        final img1 = await _ask(model, imageMessage, vision: true);
        final img2 = await _ask(model, imageMessage, vision: true);
        final aud1 = await _ask(model, audioMessage, audio: true);
        final aud2 = await _ask(model, audioMessage, audio: true);
        int share(_Answer a) => (a.firstToken - text.firstToken).inMilliseconds;
        String row(String name, _Answer a) =>
            '$tag $name: first token ${a.firstToken.inMilliseconds} ms '
            '(encoder ~${share(a)} ms), total ${a.total.inMilliseconds} ms: '
            '"${a.text}"';
        print(
          '$tag text: first token ${text.firstToken.inMilliseconds} ms: '
          '"${text.text}"',
        );
        for (final (name, a) in [
          ('image cold', img1),
          ('image warm', img2),
          ('audio cold', aud1),
          ('audio warm', aud2),
        ]) {
          print(row(name, a));
        }
        final ok = img2.text.isNotEmpty && aud2.text.isNotEmpty;
        if (variant == 'unset-unset' && ok) defaultWorked = true;
        summary.add(
          '$tag backend=${model.activeBackend?.name} load=$load ms '
          'image=${share(img2)} ms audio=${share(aud2)} ms'
          '${ok ? '' : ' EMPTY ANSWER'} | "${img2.text}" | "${aud2.text}"',
        );
      } catch (e) {
        final line = '$tag RUN FAILED: $e';
        print(line);
        summary.add(line);
      } finally {
        await model.close();
      }
    }
    print('[matrix] ===== summary =====');
    summary.forEach(print);
    if (_towers.split(',').contains('unset-unset')) {
      expect(defaultWorked, isTrue, reason: 'the default towers must work');
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
