// On-device: voice loop WITH function calling. Fixed transcript -> Gemma 3 1B
// (tools) -> onToolCall -> Inflect TTS. Asserts the tool ran and a spoken reply
// was produced.
// Run: flutter test integration_test/voice_tools_test.dart -d <device> \
//   --dart-define=HUGGINGFACE_TOKEN=$HF_TOKEN
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'voice_test_helpers.dart';

const _llmFileName = 'gemma3-1b-it-int4.litertlm';
const _ttsUrl =
    'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';
const _tools = [
  Tool(
    name: 'show_alert',
    description: 'Shows an alert dialog to the user',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'The title'},
        'message': {'type': 'string', 'description': 'The message'},
      },
      'required': ['title', 'message'],
    },
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'voice + tools: fixed transcript -> tool runs -> spoken reply',
    (tester) async {
      await FlutterEdgeAi.initialize(
        ttsBackends: const [LiteRtTtsBackend()],
        inferenceEngines: const [LiteRtLmEngine()],
      );
      final llmPath = await stagedModelPath(_llmFileName);
      expect(
        llmPath,
        isNotNull,
        reason:
            'stage $_llmFileName to the app documents dir (desktop/iOS) or '
            '/data/local/tmp/flutter_gemma_test/ (Android)',
      );
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(llmPath!).install();
      await FlutterEdgeAi.installTts()
          .fromNetwork(_ttsUrl)
          .ofType(TtsModelType.inflect)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();
      // CPU: this gate exercises the tool-calling LOOP, not GPU perf. On desktop
      // the litertlm default is GPU (Metal/Dawn), which is flaky for concurrent
      // model loads (a documented desktop-voice caveat) — pin CPU for a
      // deterministic correctness gate.
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      final chat = await model.createChat(
        tools: _tools,
        supportsFunctionCalls: true,
        modelType: ModelType.gemmaIt,
        // Same function-calling config generate_with_tools_test uses to reliably
        // elicit a show_alert call from Gemma 3 1B — toolChoice + sampling.
        // Without these the model tends to answer in prose and never calls.
        toolChoice: ToolChoice.auto,
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        tokenBuffer: 256,
      );

      var called = false;
      final session = VoiceSession.fromChat(
        recognizer: FixedTranscriptRecognizer(
          'Show an alert with title "Test" and message "Hello"',
        ),
        chat: chat,
        synthesizer: synth,
        onToolCall: (c) {
          called = true;
          return {'status': 'success', 'message': 'shown'};
        },
      );

      final events = await session.runTurn(Uint8List(0)).toList();

      expect(
        events.whereType<VoiceTranscriptEvent>().single.text,
        contains('alert'),
      );
      expect(called, isTrue, reason: 'the tool was never executed');
      final audio = events.whereType<VoiceReplyAudioEvent>().toList();
      expect(audio, isNotEmpty);
      expect(
        audio.single.pcm.any((b) => b != 0),
        isTrue,
        reason: 'silent reply',
      );

      await chat.session.close();
      await model.close();
      await synth.close();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
