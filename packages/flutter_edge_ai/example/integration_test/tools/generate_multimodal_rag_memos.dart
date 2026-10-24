// The Multimodal RAG screen's sample audio, spoken by OUR on-device TTS:
// flutter_edge_ai_speech's Matcha-TTS (litert-community/Matcha-TTS, MIT; its
// voice is LJSpeech, a public-domain recording). No recorded person and no
// macOS `say` voice (licensed for personal, non-commercial use only).
//
// - six voice memos, each a sentence or two (assets/knowledge/memos/);
// - a short two-voice "meeting" (assets/knowledge/meeting.wav): Matcha and
//   Inflect-Nano-v2 take turns, and one of the lines is a question the Live
//   tab must catch.
//
// Step 1 — synthesize on macOS (writes <documents>/knowledge_memos/*.wav at
// Matcha's own rate, 22.05 kHz; on macOS <documents> is
// ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents):
//
//   cd packages/flutter_edge_ai/example
//   flutter test integration_test/tools/generate_knowledge_memos.dart -d macos
//   (--dart-define=MULTIMODAL_RAG_AUDIO=meeting or =memos makes only one of them)
//
// Step 2 — resample to 16 kHz mono PCM16, the rate EmbeddingGemma 2's audio
// encoder and Gemma 4's audio input work at:
//
//   python3 -I integration_test/tools/convert_knowledge_memos.py \
//     ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/knowledge_memos
//
// Installs Matcha from Hugging Face when it is not installed (a no-op when it
// is). Matcha samples noise, so a rerun writes different bytes; the committed
// clips are the ones the screen was measured with.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_seed.dart';
import 'package:flutter_edge_ai_example/models/tts_model.dart';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _which = String.fromEnvironment(
  'MULTIMODAL_RAG_AUDIO',
  defaultValue: 'all',
);

/// What each memo says, keyed by the memo id in [kSeedMemos].
const memoScripts = <String, String>{
  'memo-kitchen':
      'The kitchen lights keep flickering. '
      'Please call the electrician on Thursday.',
  'memo-flight':
      'My flight to London is delayed by three hours, tell the hotel.',
  'memo-groceries': 'Pick up milk, fresh basil and lemons after work.',
  'memo-offsite':
      'Idea for the team retreat: a cooking class instead of bowling.',
  'memo-mom': 'Call Mom on Sunday to plan her birthday dinner.',
  'memo-dentist': 'The dentist moved my check-up to Tuesday at noon.',
};

/// The meeting: who says what, in order. A is Matcha-TTS (LJSpeech's
/// voice), B is Inflect-Nano-v2 — two voices, so it sounds like two people.
/// The pauses between lines are added by convert_knowledge_memos.py.
const meetingScript = [
  ('A', "Okay, quick sync before the weekend."),
  ('B', 'First, the numbers: revenue grew every quarter, and Q3 was our best.'),
  ('A', 'Nice. Put the quarterly revenue chart in the deck.'),
  ('B', 'Also, the office kitchen lights keep flickering again.'),
  ('A', "I'll call the electrician on Thursday."),
  ('B', "I'm filing the London trip expenses today, with the taxi receipt."),
  ('A', 'Wait, how much did the airport taxi cost?'),
  ('B', 'Let me check. Okay, that is all for today.'),
];

/// "Ask by voice": the question spoken, in a few phrasings and both voices,
/// to measure audio → photo retrieval; question_1_B is the bundled one
/// (assets/knowledge/question.wav, see convert_knowledge_memos.py).
const questionScripts = [
  ('A', 'How much was the airport taxi?'),
  ('B', 'How much was the airport taxi?'),
  ('A', 'What did the taxi to the airport cost?'),
  ('B', 'How much did I pay for the airport cab?'),
  ('A', 'Show me the receipt for the airport taxi.'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('synthesizes the sample memos and meeting with Matcha', (
    tester,
  ) async {
    expect(memoScripts.keys.toSet(), {
      for (final memo in kSeedMemos) memo.id,
    }, reason: 'one script per seeded memo');
    await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);
    await FlutterEdgeAi.installTts()
        .fromNetwork(TtsModel.matcha.baseUrl)
        .ofType(TtsModel.matcha.ttsModelType)
        .install();
    final synth = await FlutterEdgeAi.getActiveTts();
    try {
      final out = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/knowledge_memos',
      );
      await out.create(recursive: true);
      Future<void> write(String name, Uint8List pcm) =>
          File('${out.path}/$name').writeAsBytes(
            AudioConverter.pcmToWav(pcm, sampleRate: synth.sampleRate),
            flush: true,
          );
      if (_which == 'all' || _which == 'memos') {
        for (final memo in kSeedMemos) {
          final script = memoScripts[memo.id]!;
          final pcm = Uint8List.fromList(await synth.synthesize(script));
          await write(memo.assetName, pcm);
          debugPrint(
            '[memos] ${memo.assetName}: '
            '${(pcm.length / 2 / synth.sampleRate).toStringAsFixed(2)} s — '
            '"$script"',
          );
        }
      }
      if (_which == 'all' || _which == 'meeting') {
        await File('${out.path}/meeting_lines.json').writeAsString(
          jsonEncode([
            for (final (who, line) in meetingScript)
              {'speaker': who, 'text': line},
          ]),
        );
        await _speakMeetingLines(synth, 'A', write);
        await _speakQuestions(synth, 'A', write);
      }
      debugPrint('[memos] wrote to ${out.path}');
    } finally {
      await synth.close();
    }
    if (_which == 'all' || _which == 'meeting') {
      // Speaker B: Inflect-Nano-v2, then Matcha is made active again.
      await FlutterEdgeAi.installTts()
          .fromNetwork(TtsModel.inflect.baseUrl)
          .ofType(TtsModel.inflect.ttsModelType)
          .install();
      final inflect = await FlutterEdgeAi.getActiveTts();
      try {
        final out = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/knowledge_memos',
        );
        Future<void> write(String name, Uint8List pcm) =>
            File('${out.path}/$name').writeAsBytes(
              AudioConverter.pcmToWav(pcm, sampleRate: inflect.sampleRate),
              flush: true,
            );
        await _speakMeetingLines(inflect, 'B', write);
        await _speakQuestions(inflect, 'B', write);
      } finally {
        await inflect.close();
      }
      await FlutterEdgeAi.installTts()
          .fromNetwork(TtsModel.matcha.baseUrl)
          .ofType(TtsModel.matcha.ttsModelType)
          .install();
    }
  });
}

/// Writes [speaker]'s meeting lines as `meeting_<n>_<speaker>.wav`, at the
/// synthesizer's own rate.
Future<void> _speakMeetingLines(
  SpeechSynthesizer synth,
  String speaker,
  Future<void> Function(String name, Uint8List pcm) write,
) async {
  for (final (i, (who, line)) in meetingScript.indexed) {
    if (who != speaker) continue;
    final pcm = Uint8List.fromList(await synth.synthesize(line));
    final name = 'meeting_${(i + 1).toString().padLeft(2, '0')}_$who.wav';
    await write(name, pcm);
    debugPrint(
      '[memos] $name: ${(pcm.length / 2 / synth.sampleRate).toStringAsFixed(2)}'
      ' s at ${synth.sampleRate} Hz — "$line"',
    );
  }
}

/// Writes [speaker]'s spoken questions as `question_<n>_<speaker>.wav`.
Future<void> _speakQuestions(
  SpeechSynthesizer synth,
  String speaker,
  Future<void> Function(String name, Uint8List pcm) write,
) async {
  for (final (i, (who, line)) in questionScripts.indexed) {
    if (who != speaker) continue;
    final pcm = Uint8List.fromList(await synth.synthesize(line));
    await write('question_${i + 1}_$who.wav', pcm);
    debugPrint('[memos] question_${i + 1}_$who.wav — "$line"');
  }
}
