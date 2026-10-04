// On-device integration test: the full voice loop (STT -> LLM -> TTS) driven
// by VoiceSession.fromChat, end-to-end on the bundled clip — no mic/speaker.
//
// Installs moonshine-tiny STT, Gemma 3 1B IT (.litertlm, no tools) and
// Inflect TTS from HuggingFace, activates all three via the public API, then
// runs one VoiceSession turn and asserts transcript -> reply text -> reply
// audio -> turn-complete all landed with real (non-empty, non-silent)
// content.
//
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/voice_loop_test.dart -d <device> \
//     --dart-define=HF_TOKEN=$HF_TOKEN
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ── STT: moonshine-tiny — same URLs as stt_moonshine_test.dart. Public repos,
// token is optional there but harmless to pass. ──
const _sttModelUrl =
    'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite';
const _sttTokenizerUrl =
    'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json';

// ── LLM: Gemma 3 1B IT, .litertlm, gated repo (needsAuth: true in
// example/lib/models/model.dart Model.gemma3_1B). Same desktopUrl used by
// active_model_restore_test.dart / litertlm_ffi_test.dart's fromNetwork
// install pattern, and the exact model VoiceScreen picks for this loop. Small
// (0.5GB) on purpose — this test is a release gate, not a quality bar. ──
const _llmModelUrl =
    'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

// ── TTS: Inflect-Nano-v2 (the fastest voice) — 2 tflites from this repo +
// 4 G2P files fetched cross-repo from Matcha (routed by fetchLocationFor).
// Public repos, no token needed. ──
const _ttsModelUrl =
    'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';

// The rest of the suite reads HUGGINGFACE_TOKEN (litertlm_ffi_test.dart et al);
// this file historically read HF_TOKEN. Accept both so the repo's habitual
// --dart-define does not silently yield an empty token and push the run onto
// the tokenless gated-download path.
const _hfTokenStandard = String.fromEnvironment('HUGGINGFACE_TOKEN');
const _hfTokenLegacy = String.fromEnvironment('HF_TOKEN');
final _hfToken = _hfTokenStandard.isNotEmpty
    ? _hfTokenStandard
    : _hfTokenLegacy;

/// Prefer a device-local staged model file (no network, no token) — the
/// convention the other integration tests use. Desktop and iOS read it from the
/// app documents dir as `gemma3-1b-it-int4.litertlm`; Android (Firebase Test
/// Lab) reads it from `/data/local/tmp/flutter_gemma_test/`.
/// Returns null when no staged file is present (CI → network install).
Future<String?> _stagedLlmPath() async {
  // Android (Firebase Test Lab): the model is pushed to the device via
  // `--other-files /data/local/tmp/flutter_gemma_test/...` — no network/token.
  if (Platform.isAndroid) {
    const p = '/data/local/tmp/flutter_gemma_test/gemma3-1b-it-int4.litertlm';
    return File(p).existsSync() ? p : null;
  }
  if (!(Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows ||
      Platform.isIOS)) {
    return null;
  }
  final docs = await getApplicationDocumentsDirectory();
  final path = '${docs.path}/gemma3-1b-it-int4.litertlm';
  return File(path).existsSync() ? path : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'voice loop: bundled clip -> STT -> LLM -> TTS produces spoken reply',
    (tester) async {
      // 1. Register the STT/TTS/inference backends and install + activate
      //    STT (moonshine), a small no-tools LLM (Gemma 3 1B), and TTS
      //    (Inflect).
      await FlutterEdgeAi.initialize(
        huggingFaceToken: _hfToken.isEmpty ? null : _hfToken,
        sttBackends: const [LiteRtSttBackend()],
        ttsBackends: const [LiteRtTtsBackend()],
        inferenceEngines: const [LiteRtLmEngine()],
      );

      await FlutterEdgeAi.installStt()
          .modelFromNetwork(
            _sttModelUrl,
            token: _hfToken.isEmpty ? null : _hfToken,
          )
          .tokenizerFromNetwork(
            _sttTokenizerUrl,
            token: _hfToken.isEmpty ? null : _hfToken,
          )
          .ofType(SttModelType.moonshine)
          .install();

      // Install the LLM from a device-local staged .litertlm (no network, no
      // token) — the convention used by the other integration tests
      // (litertlm_ffi_test.dart / active_model_restore_test.dart). A run
      // without a staged file falls back to the gated network install, which
      // is reported loudly below: a silent fallback would hide a broken
      // `--other-files` push and burn 0.5 GB per run on a path the test was
      // written to avoid.
      final llm = FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      );
      final llmLocalPath = await _stagedLlmPath();
      if (llmLocalPath != null) {
        debugPrint('[voice_loop] LLM from staged file: $llmLocalPath');
        await llm.fromFile(llmLocalPath).install();
      } else {
        debugPrint(
          '[voice_loop] no staged LLM found — falling back to the gated '
          'network install',
        );
        expect(
          _hfToken.isNotEmpty,
          isTrue,
          reason:
              'No device-local staged LLM and no HuggingFace token, so the '
              'gated network fallback cannot authenticate. Stage the model '
              '(Android: --other-files '
              '/data/local/tmp/flutter_gemma_test/gemma3-1b-it-int4.litertlm; '
              'desktop/iOS: app documents dir) or pass '
              '--dart-define=HUGGINGFACE_TOKEN=...',
        );
        await llm
            .fromNetwork(
              _llmModelUrl,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .install();
      }

      await FlutterEdgeAi.installTts()
          .fromNetwork(_ttsModelUrl)
          .ofType(TtsModelType.inflect)
          .install();

      final recognizer = await FlutterEdgeAi.getActiveStt();
      final synthesizer = await FlutterEdgeAi.getActiveTts();
      // CPU LLM: the voice path loads the Inflect TTS graphs (Metal) alongside
      // the LLM; a concurrent GPU (Metal) engine_create dies mid-weight-convert
      // on macOS. Same CPU pin as voice_tools/voice_agent. Android/desktop GPU
      // is unaffected, but CPU keeps this release gate green on every platform.
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      final chat = await model.createChat(
        tokenBuffer: 256,
        tools: const [],
        systemInstruction: 'Reply in one short sentence.',
        maxOutputTokens: 32,
      );

      // 2. Load the bundled clip -> 16 kHz mono PCM.
      final data = await rootBundle.load('assets/test/test_audio.wav');
      final parsed = AudioConverter.parseWav(data.buffer.asUint8List());
      final pcm = AudioConverter.toPCM16kHzMono(
        parsed.pcmData,
        sourceSampleRate: parsed.sampleRate,
        sourceChannels: parsed.channels,
      );

      // 3. Run one voice turn.
      final session = VoiceSession.fromChat(
        recognizer: recognizer,
        chat: chat,
        synthesizer: synthesizer,
      );
      // Per-stage latency timing (STT / LLM / TTS) for the FTL measurement.
      final sw = Stopwatch()..start();
      int? tStt, tLlmFirst, tLlmLast, tTts, tTotal;
      final events = <VoiceEvent>[];
      await for (final e in session.runTurn(pcm)) {
        events.add(e);
        if (e is VoiceTranscriptEvent) {
          tStt = sw.elapsedMilliseconds;
        } else if (e is VoiceReplyTextEvent) {
          tLlmFirst ??= sw.elapsedMilliseconds;
          tLlmLast = sw.elapsedMilliseconds;
        } else if (e is VoiceReplyAudioEvent) {
          tTts = sw.elapsedMilliseconds;
        } else if (e is VoiceTurnCompleteEvent) {
          tTotal = sw.elapsedMilliseconds;
        }
      }
      String delta(int? a, int? b) =>
          (a != null && b != null) ? '${a - b}ms' : 'n/a';
      debugPrint(
        '[voice_loop][timing] STT=${tStt ?? 'n/a'}ms '
        'LLM_ttft=${delta(tLlmFirst, tStt)} LLM=${delta(tLlmLast, tStt)} '
        'TTS=${delta(tTts, tLlmLast)} TURN_TOTAL=${tTotal ?? 'n/a'}ms',
      );

      // 4. Assert the full pipeline produced output.
      final transcript = events.whereType<VoiceTranscriptEvent>().single.text;
      final replyText = events
          .whereType<VoiceReplyTextEvent>()
          .map((e) => e.chunk)
          .join();
      final audio = events.whereType<VoiceReplyAudioEvent>().toList();
      final complete = events.whereType<VoiceTurnCompleteEvent>().single;
      final spokenSeconds =
          audio.single.pcm.length / 2 / audio.single.sampleRate;
      debugPrint('[voice_loop] transcript: "$transcript"');
      debugPrint('[voice_loop] reply: "$replyText"');
      debugPrint(
        '[voice_loop] spoken audio: ${spokenSeconds.toStringAsFixed(1)}s '
        '(${audio.single.pcm.length} bytes @ ${audio.single.sampleRate} Hz)',
      );

      expect(
        transcript.trim(),
        isNotEmpty,
        reason: 'STT produced no transcript',
      );
      expect(replyText.trim(), isNotEmpty, reason: 'LLM produced no reply');
      expect(audio, isNotEmpty, reason: 'TTS produced no audio event');
      expect(audio.single.pcm.length, greaterThan(0));
      expect(audio.single.sampleRate, 24000); // Inflect is 24 kHz
      expect(
        audio.single.pcm.any((b) => b != 0),
        isTrue,
        reason: 'reply PCM is all-silence',
      );
      expect(complete.replyText, replyText);

      await chat.session.close();
      await model.close();
      await recognizer.close();
      await synthesizer.close();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
