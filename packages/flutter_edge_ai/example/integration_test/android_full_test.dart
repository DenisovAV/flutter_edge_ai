/// Full Android FFI integration tests — models pre-pushed to /data/local/tmp/
/// Push models: adb push <model>.litertlm /data/local/tmp/flutter_gemma_test/
/// Run: cd example && flutter test integration_test/android_full_test.dart -d <device>
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _dir = '/data/local/tmp/flutter_gemma_test';
const _gemma3_1b = '$_dir/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const _qwen3_06 = '$_dir/Qwen3-0.6B.litertlm';
const _gemma3n = '$_dir/gemma-3n-E2B-it-int4.litertlm';
const _gemma4 = '$_dir/gemma-4-E2B-it.litertlm';
const _imgPath = '$_dir/test_image.jpg';
const _audioPath = '$_dir/test_audio.wav';

late Uint8List _testImage;
late Uint8List _testAudio;

Future<void> _install(String path) async {
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromFile(path).install();
}

Future<String> _chat(
  PreferredBackend backend,
  int maxTokens,
  String prompt, {
  bool supportImage = false,
  bool supportAudio = false,
  bool enableThinking = false,
  Uint8List? image,
  Uint8List? audio,
}) async {
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: backend,
    supportImage: supportImage,
    maxNumImages: supportImage ? 1 : null,
    supportAudio: supportAudio,
  );
  final session = await model.createSession(
    temperature: 0.8,
    topK: 1,
    enableVisionModality: supportImage,
    enableAudioModality: supportAudio,
    enableThinking: enableThinking,
  );
  await session.addQueryChunk(
    Message(text: prompt, isUser: true, imageBytes: image, audioBytes: audio),
  );
  final r = await session.getResponse();
  await session.close();
  await model.close();
  return r;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    _testImage = File(_imgPath).existsSync()
        ? File(_imgPath).readAsBytesSync()
        : Uint8List(0);
    _testAudio = File(_audioPath).existsSync()
        ? File(_audioPath).readAsBytesSync()
        : Uint8List(0);
    print('Assets: image=${_testImage.length}B, audio=${_testAudio.length}B');
  });

  group('Gemma3-1B', () {
    setUpAll(() async {
      await _install(_gemma3_1b);
    });
    testWidgets('CPU', (t) async {
      final r = await _chat(PreferredBackend.cpu, 4096, 'Say hi');
      print('[G3-1B CPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('GPU', (t) async {
      final r = await _chat(PreferredBackend.gpu, 4096, 'What is 2+2?');
      print('[G3-1B GPU] $r');
      expect(r, isNotEmpty);
    });
  });

  group('Qwen3-0.6B', () {
    setUpAll(() async {
      await _install(_qwen3_06);
    });
    testWidgets('CPU', (t) async {
      final r = await _chat(PreferredBackend.cpu, 4096, 'Say hi');
      print('[Qwen CPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('GPU', (t) async {
      final r = await _chat(PreferredBackend.gpu, 4096, 'What is 2+2?');
      print('[Qwen GPU] $r');
      expect(r, isNotEmpty);
    });
  });

  group('Gemma3n-E2B', () {
    setUpAll(() async {
      await _install(_gemma3n);
    });
    testWidgets('CPU', (t) async {
      final r = await _chat(PreferredBackend.cpu, 4096, 'Say hi');
      print('[G3n CPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('GPU', (t) async {
      final r = await _chat(PreferredBackend.gpu, 4096, 'What is 2+2?');
      print('[G3n GPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('vision', (t) async {
      if (_testImage.isEmpty) {
        print('[G3n vision] SKIP');
        return;
      }
      final r = await _chat(
        PreferredBackend.gpu,
        4096,
        'Describe this image',
        supportImage: true,
        image: _testImage,
      );
      print('[G3n vision] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('audio', (t) async {
      if (_testAudio.isEmpty) {
        print('[G3n audio] SKIP');
        return;
      }
      final r = await _chat(
        PreferredBackend.cpu,
        4096,
        'What did you hear?',
        supportAudio: true,
        audio: _testAudio,
      );
      print('[G3n audio] $r');
      expect(r, isNotEmpty);
    });
  });

  group('Gemma4-E2B', () {
    setUpAll(() async {
      await _install(_gemma4);
    });
    testWidgets('CPU', (t) async {
      final r = await _chat(PreferredBackend.cpu, 4096, 'Say hi');
      print('[G4 CPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('GPU', (t) async {
      final r = await _chat(PreferredBackend.gpu, 4096, 'What is 2+2?');
      print('[G4 GPU] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('vision', (t) async {
      if (_testImage.isEmpty) {
        print('[G4 vision] SKIP');
        return;
      }
      final r = await _chat(
        PreferredBackend.gpu,
        4096,
        'Describe this image',
        supportImage: true,
        image: _testImage,
      );
      print('[G4 vision] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('audio', (t) async {
      if (_testAudio.isEmpty) {
        print('[G4 audio] SKIP');
        return;
      }
      final r = await _chat(
        PreferredBackend.gpu,
        4096,
        'What did you hear?',
        supportAudio: true,
        audio: _testAudio,
      );
      print('[G4 audio] $r');
      expect(r, isNotEmpty);
    });
    testWidgets('thinking', (t) async {
      final r = await _chat(
        PreferredBackend.gpu,
        4096,
        'Why is the sky blue?',
        enableThinking: true,
      );
      print('[G4 thinking] ${r.substring(0, r.length.clamp(0, 100))}...');
      expect(r, isNotEmpty);
    });
  });
}
