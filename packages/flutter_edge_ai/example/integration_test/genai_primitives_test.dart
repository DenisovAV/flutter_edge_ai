/// End-to-end integration tests for the genai_primitives adoption surface
/// (#181): `sendMessage` / `sendMessageStream` / `generateContent` /
/// `generateContentStream` on `InferenceChat`, exercised across ALL
/// generation types — text, vision, audio, thinking, tool calls, and
/// multi-turn history — not just plain text.
///
/// Model: `gemma-4-E2B-it.litertlm` (multimodal + thinking + tools in one
/// model — mirrors the setup machinery in litertlm_ffi_test.dart).
///
/// Run:
///   flutter test integration_test/genai_primitives_test.dart -d <device>
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/genai.dart';
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

Uint8List _testImage = Uint8List(0);
Uint8List _testAudio = Uint8List(0);

const _getWeatherTool = Tool(
  name: 'get_weather',
  description: 'Get the current weather for a location.',
  parameters: {
    'type': 'object',
    'properties': {
      'location': {'type': 'string', 'description': 'City name, e.g. Berlin.'},
    },
    'required': ['location'],
  },
);

String? _localPath(String filename) {
  if (Platform.isAndroid) return '$_androidDir/$filename';
  if (Platform.isMacOS) return '$_macosDir/$filename';
  if (Platform.isLinux) return '$_linuxDir/$filename';
  if (Platform.isWindows) return '$_windowsDir\\$filename';
  if (Platform.isIOS) {
    const iosDocs = String.fromEnvironment('IOS_TEST_DOCS_DIR');
    if (iosDocs.isNotEmpty) {
      final p = '$iosDocs/$filename';
      if (File(p).existsSync()) return p;
    }
    return null;
  }
  return null;
}

Future<void> _install() async {
  final localPath = _localPath('gemma-4-E2B-it.litertlm');
  if (localPath != null && File(localPath).existsSync()) {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(localPath).install();
  } else {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(_gemma4Url, token: _token).install();
  }
}

// Group-scoped model instance — mirrors litertlm_ffi_test.dart's
// _ensureModel/_closeSharedModel: creating one InferenceModel per group and
// reusing it across tests avoids repeated GPU engine_create overhead.
InferenceModel? _sharedModel;

Future<InferenceModel> _ensureModel(int maxTokens) async {
  if (_sharedModel != null) return _sharedModel!;
  _sharedModel = await FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    maxNumImages: 1,
    supportAudio: true,
  );
  return _sharedModel!;
}

Future<void> _closeSharedModel() async {
  if (_sharedModel != null) {
    await _sharedModel!.close();
    _sharedModel = null;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    await _install();

    for (final path in [
      '$_androidDir/test_image.jpg',
      '$_macosDir/test_image.jpg',
      if (Platform.isLinux) '$_linuxDir/test_image.jpg',
      if (Platform.isWindows) '$_windowsDir\\test_image.jpg',
      '${Platform.environment['HOME']}/Downloads/test_image.jpg',
    ]) {
      if (File(path).existsSync()) {
        _testImage = File(path).readAsBytesSync();
        break;
      }
    }
    if (_testImage.isEmpty) {
      try {
        final data = await rootBundle.load('assets/test/test_image.jpg');
        _testImage = data.buffer.asUint8List();
      } catch (_) {
        /* asset not bundled — leave empty */
      }
    }

    for (final path in [
      '$_androidDir/test_audio.wav',
      '$_macosDir/test_audio.wav',
      if (Platform.isLinux) '$_linuxDir/test_audio.wav',
      if (Platform.isWindows) '$_windowsDir\\test_audio.wav',
    ]) {
      if (File(path).existsSync()) {
        _testAudio = File(path).readAsBytesSync();
        break;
      }
    }
    if (_testAudio.isEmpty) {
      try {
        final data = await rootBundle.load('assets/test/test_audio.wav');
        _testAudio = data.buffer.asUint8List();
      } catch (_) {
        /* asset not bundled — leave empty */
      }
    }
    print('Platform: ${Platform.operatingSystem}');
    print('Assets: image=${_testImage.length}B, audio=${_testAudio.length}B');
  });

  tearDownAll(_closeSharedModel);

  testWidgets('sendMessage — text', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();
    final reply = await chat.sendMessage(
      ChatMessage.user('Say hello in one word.'),
    );
    expect(reply.role, ChatMessageRole.model);
    expect(
      reply.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );
    await chat.session.close();
  });

  testWidgets('sendMessageStream — text', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();
    final chunks = <ChatMessage>[];
    await for (final c in chat.sendMessageStream(
      ChatMessage.user('Count to three.'),
    )) {
      chunks.add(c);
    }
    expect(chunks, isNotEmpty);
    expect(chunks.every((c) => c.role == ChatMessageRole.model), isTrue);
    await chat.session.close();
  });

  testWidgets('sendMessage — vision', (tester) async {
    if (_testImage.isEmpty) {
      print('[genai vision] SKIP: no image');
      return;
    }
    final model = await _ensureModel(4096);
    final chat = await model.createChat(supportImage: true);
    final reply = await chat.sendMessage(
      ChatMessage.user(
        '',
        parts: [
          TextPart('Describe this image briefly'),
          DataPart(_testImage, mimeType: 'image/jpeg'),
        ],
      ),
    );
    expect(reply.role, ChatMessageRole.model);
    expect(
      reply.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );
    await chat.session.close();
  });

  testWidgets('sendMessage — audio', (tester) async {
    if (_testAudio.isEmpty) {
      print('[genai audio] SKIP: no audio');
      return;
    }
    final model = await _ensureModel(4096);
    final chat = await model.createChat(supportAudio: true);
    final reply = await chat.sendMessage(
      ChatMessage.user(
        '',
        parts: [
          TextPart('What did you hear?'),
          DataPart(_testAudio, mimeType: 'audio/wav'),
        ],
      ),
    );
    expect(reply.role, ChatMessageRole.model);
    expect(
      reply.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );
    await chat.session.close();
  });

  testWidgets('sendMessage — thinking', (tester) async {
    final model = await _ensureModel(4096);
    final chat = await model.createChat(enableThinking: true);
    final reply = await chat.sendMessage(
      ChatMessage.user('Why is the sky blue?'),
    );
    expect(reply.role, ChatMessageRole.model);
    expect(
      reply.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );
    final thinkingParts = reply.parts.whereType<ThinkingPart>().toList();
    if (thinkingParts.isNotEmpty) {
      // Model-dependent: only assert non-empty content when present, don't
      // hard-require a ThinkingPart to show up.
      expect(thinkingParts.map((p) => p.text).join(), isNotEmpty);
    }
    await chat.session.close();
  });

  testWidgets('sendMessage — tool call round-trip', (tester) async {
    final model = await _ensureModel(4096);
    final chat = await model.createChat(
      supportsFunctionCalls: true,
      tools: const [_getWeatherTool],
      modelType: ModelType.gemma4,
    );

    final reply = await chat.sendMessage(
      ChatMessage.user('What is the weather like in Berlin?'),
    );
    expect(reply.role, ChatMessageRole.model);

    final toolCalls = reply.parts
        .whereType<ToolPart>()
        .where((p) => p.kind == ToolPartKind.call)
        .toList();
    final text = reply.parts.whereType<TextPart>().map((p) => p.text).join();

    // Model may either issue the tool call, or answer directly in text —
    // both are valid; assert non-empty either way.
    expect(
      toolCalls.isNotEmpty || text.isNotEmpty,
      isTrue,
      reason: 'Reply must contain either a tool call or text',
    );

    if (toolCalls.isNotEmpty) {
      final call = toolCalls.first;
      expect(call.toolName, isNotEmpty);

      final followUp = await chat.sendMessage(
        ChatMessage(
          role: ChatMessageRole.user,
          parts: [
            ToolPart.result(
              callId: call.callId,
              toolName: call.toolName,
              result: const {'temperature_c': 18, 'condition': 'partly cloudy'},
            ),
          ],
        ),
      );
      expect(followUp.role, ChatMessageRole.model);
      final followUpText = followUp.parts
          .whereType<TextPart>()
          .map((p) => p.text)
          .join();
      final followUpCalls = followUp.parts
          .whereType<ToolPart>()
          .where((p) => p.kind == ToolPartKind.call)
          .toList();
      expect(
        followUpText.isNotEmpty || followUpCalls.isNotEmpty,
        isTrue,
        reason: 'Follow-up reply must contain either text or another call',
      );
    } else {
      print('[genai tool call] model answered directly: "$text"');
    }

    await chat.session.close();
  });

  testWidgets('generateContent — single user message', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();
    final reply = await chat.generateContent([ChatMessage.user('Say hello.')]);
    expect(reply.role, ChatMessageRole.model);
    expect(
      reply.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );
    await chat.session.close();
  });

  testWidgets('generateContentStream — single user message', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();
    final chunks = <ChatMessage>[];
    await for (final c in chat.generateContentStream([
      ChatMessage.user('Say hello.'),
    ])) {
      chunks.add(c);
    }
    expect(chunks, isNotEmpty);
    expect(chunks.every((c) => c.role == ChatMessageRole.model), isTrue);
    await chat.session.close();
  });

  testWidgets('generateContent — multi-turn list', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();
    final reply = await chat.generateContent([
      ChatMessage.user('My name is Sasha.'),
      ChatMessage.model('Nice to meet you, Sasha.'),
      ChatMessage.user('What is my name?'),
    ]);
    expect(reply.role, ChatMessageRole.model);
    final text = reply.parts.whereType<TextPart>().map((p) => p.text).join();
    expect(text, isNotEmpty);
    print('[genai generateContent multi-turn] $text');
    await chat.session.close();
  });

  testWidgets('sendMessage — multi-turn history retained', (tester) async {
    final model = await _ensureModel(1024);
    final chat = await model.createChat();

    final r1 = await chat.sendMessage(ChatMessage.user('My name is Sasha.'));
    expect(
      r1.parts.whereType<TextPart>().map((p) => p.text).join(),
      isNotEmpty,
    );

    final r2 = await chat.sendMessage(ChatMessage.user('What is my name?'));
    final text2 = r2.parts.whereType<TextPart>().map((p) => p.text).join();
    expect(text2, isNotEmpty);
    print('[genai multi-turn history] $text2');

    await chat.session.close();
  });
}
