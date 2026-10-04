/// Full desktop integration tests via FlutterEdgeAi plugin API.
/// Tests: text sync, streaming, vision, audio, thinking mode.
///
/// Run: cd example && flutter test integration_test/desktop_full_test.dart -d macos
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

// Models in the app sandbox container
const _containerDir =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents';
const _gemma3_1bPath =
    '$_containerDir/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const _gemma4Path = '$_containerDir/gemma-4-E2B-it.litertlm';
const _gemma3nPath = '$_containerDir/gemma-3n-E2B-it-int4.litertlm';
const _testImagePath = '$_containerDir/test_image.png';
const _testAudioPath = '$_containerDir/test_audio.wav';

late Uint8List _testImage;
late Uint8List _testAudio;

Future<void> _install(String path) async {
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromFile(path).install();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    _testImage = File(_testImagePath).readAsBytesSync();
    _testAudio = File(_testAudioPath).readAsBytesSync();
    print('Assets: image=${_testImage.length}B, audio=${_testAudio.length}B');
  });

  // ── Gemma 3 1B: text ──────────────────────────────────────────────

  group('Gemma3-1B text', () {
    testWidgets('sync CPU', (t) async {
      await _install(_gemma3_1bPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));
      final r = await session.getResponse();
      print('[g3-1b cpu sync] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('stream GPU', (t) async {
      await _install(_gemma3_1bPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'Say hello', isUser: true),
      );
      final chunks = <String>[];
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
      }
      print('[g3-1b gpu stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);
      await session.close();
      await model.close();
    });
  });

  // ── Gemma 4 E2B: text, stream, vision, audio, thinking ───────────

  group('Gemma4 E2B', () {
    testWidgets('sync GPU', (t) async {
      await _install(_gemma4Path);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'What is 2+2?', isUser: true),
      );
      final r = await session.getResponse();
      print('[g4 gpu sync] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('stream GPU', (t) async {
      await _install(_gemma4Path);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'Say hello', isUser: true),
      );
      final chunks = <String>[];
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
      }
      print('[g4 gpu stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('vision GPU', (t) async {
      await _install(_gemma4Path);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
        supportImage: true,
        maxNumImages: 1,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableVisionModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'Describe this image briefly',
          isUser: true,
          imageBytes: _testImage,
        ),
      );
      final r = await session.getResponse();
      print('[g4 gpu vision] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('audio GPU', (t) async {
      await _install(_gemma4Path);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
        supportAudio: true,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableAudioModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'What did you hear?',
          isUser: true,
          audioBytes: _testAudio,
        ),
      );
      final r = await session.getResponse();
      print('[g4 gpu audio] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('thinking GPU', (t) async {
      await _install(_gemma4Path);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableThinking: true,
      );
      await session.addQueryChunk(
        const Message(
          text: 'Why is the sky blue? Think step by step.',
          isUser: true,
        ),
      );
      final chunks = <String>[];
      bool hasThinking = false;
      bool hasText = false;
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
        if (c.contains('<|channel>thought')) hasThinking = true;
        if (!c.contains('<|channel>')) hasText = true;
      }
      final full = chunks.join();
      print(
        '[g4 gpu thinking] ${chunks.length} chunks, thinking=$hasThinking, text=$hasText',
      );
      print(
        '[g4 gpu thinking] first 200: ${full.substring(0, full.length.clamp(0, 200))}',
      );
      expect(chunks, isNotEmpty);
      expect(hasThinking, true, reason: 'Should have thinking chunks');
      expect(hasText, true, reason: 'Should have text chunks');
      await session.close();
      await model.close();
    });
  });

  // ── Gemma 3n E2B: text, stream, vision, audio ────────────────────

  group('Gemma3n E2B', () {
    testWidgets('sync CPU', (t) async {
      await _install(_gemma3nPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));
      final r = await session.getResponse();
      print('[g3n cpu sync] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('stream GPU', (t) async {
      await _install(_gemma3nPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'Say hello', isUser: true),
      );
      final chunks = <String>[];
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
      }
      print('[g3n gpu stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('vision GPU', (t) async {
      await _install(_gemma3nPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
        supportImage: true,
        maxNumImages: 1,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableVisionModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'Describe this image briefly',
          isUser: true,
          imageBytes: _testImage,
        ),
      );
      final r = await session.getResponse();
      print('[g3n gpu vision] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('audio CPU', (t) async {
      await _install(_gemma3nPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
        supportAudio: true,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableAudioModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'What did you hear?',
          isUser: true,
          audioBytes: _testAudio,
        ),
      );
      final r = await session.getResponse();
      print('[g3n cpu audio] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });

    testWidgets('audio GPU', (t) async {
      await _install(_gemma3nPath);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
        supportAudio: true,
      );
      final session = await model.createSession(
        temperature: 0.8,
        topK: 1,
        enableAudioModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'What did you hear?',
          isUser: true,
          audioBytes: _testAudio,
        ),
      );
      final r = await session.getResponse();
      print('[g3n gpu audio] $r');
      expect(r, isNotEmpty);
      await session.close();
      await model.close();
    });
  });
}
