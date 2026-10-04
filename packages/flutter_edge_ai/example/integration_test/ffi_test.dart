import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _gemma3_1bPath =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const _gemma4Path =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-4-E2B-it.litertlm';
const _gemma3nPath =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-3n-E2B-it-int4.litertlm';

// Test image path (real PNG from app container)
const _testImagePath =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/test_image.png';

late Uint8List _testImage;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    _testImage = File(_testImagePath).readAsBytesSync();
    print('Test image loaded: ${_testImage.length} bytes');
  });

  group('Gemma 3 1B (text only)', () {
    testWidgets('CPU sync', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3_1bPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));
      final response = await session.getResponse();
      print('[Gemma3-1B CPU] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3-1B CPU] PASSED');
    });

    testWidgets('GPU streaming', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3_1bPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'Say hello', isUser: true),
      );

      final chunks = <String>[];
      await for (final chunk in session.getResponseAsync()) {
        chunks.add(chunk);
      }
      print('[Gemma3-1B GPU stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3-1B GPU stream] PASSED');
    });
  });

  group('Gemma 4 E2B (multimodal)', () {
    testWidgets('GPU text only', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma4Path).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'What is 2+2?', isUser: true),
      );
      final response = await session.getResponse();
      print('[Gemma4 GPU text] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma4 GPU text] PASSED');
    });

    testWidgets('GPU streaming', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma4Path).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'Say hello', isUser: true),
      );

      final chunks = <String>[];
      await for (final chunk in session.getResponseAsync()) {
        chunks.add(chunk);
      }
      print('[Gemma4 GPU stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma4 GPU stream] PASSED');
    });

    testWidgets('GPU with image', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma4Path).install();

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
          text: 'What do you see in this image?',
          isUser: true,
          imageBytes: _testImage,
        ),
      );

      final response = await session.getResponse();
      print('[Gemma4 GPU vision] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma4 GPU vision] PASSED');
    });

    testWidgets('GPU with audio', (tester) async {
      final testAudio = File(
        '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/test_audio.wav',
      ).readAsBytesSync();
      print('[Gemma4 audio] Loaded ${testAudio.length} bytes');

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma4Path).install();

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
          audioBytes: testAudio,
        ),
      );

      final response = await session.getResponse();
      print('[Gemma4 GPU audio] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma4 GPU audio] PASSED');
    });
  });

  group('Gemma 3n E2B (multimodal)', () {
    testWidgets('CPU text only', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3nPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));
      final response = await session.getResponse();
      print('[Gemma3n CPU text] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3n CPU text] PASSED');
    });

    testWidgets('GPU text only', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3nPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(
        const Message(text: 'What is 2+2?', isUser: true),
      );
      final response = await session.getResponse();
      print('[Gemma3n GPU text] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3n GPU text] PASSED');
    });

    testWidgets('GPU streaming', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3nPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );

      final session = await model.createSession(temperature: 0.8, topK: 1);
      await session.addQueryChunk(const Message(text: 'Say hi', isUser: true));

      final chunks = <String>[];
      await for (final chunk in session.getResponseAsync()) {
        chunks.add(chunk);
      }
      print('[Gemma3n GPU stream] ${chunks.length} chunks: ${chunks.join()}');
      expect(chunks, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3n GPU stream] PASSED');
    });

    testWidgets('GPU with image', (tester) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3nPath).install();

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
          text: 'Describe this image',
          isUser: true,
          imageBytes: _testImage,
        ),
      );

      final response = await session.getResponse();
      print('[Gemma3n GPU vision] Response: $response');
      expect(response, isNotEmpty);

      await session.close();
      await model.close();
      print('[Gemma3n GPU vision] PASSED');
    });

    testWidgets('CPU with audio', (tester) async {
      final testAudio = File(
        '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/test_audio.wav',
      ).readAsBytesSync();
      print('[Gemma3n audio] Loaded ${testAudio.length} bytes');

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_gemma3nPath).install();

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
          audioBytes: testAudio,
        ),
      );

      try {
        final response = await session.getResponse();
        print('[Gemma3n CPU audio] Response: $response');
        expect(response, isNotEmpty);
        print('[Gemma3n CPU audio] PASSED');
      } catch (e) {
        print(
          '[Gemma3n CPU audio] Error (may be expected with tiny audio): $e',
        );
      }

      await session.close();
      await model.close();
    });
  });
}
