import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/stt_model.dart';
import 'package:flutter_gemma_example/models/tts_model.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/utils/audio_converter.dart';
import 'package:flutter_gemma_example/utils/platform_io_helper.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Voice loop reference screen — push-to-talk STT -> LLM -> TTS driven by
/// [VoiceSession]. Mirrors `SttScreen` for capture (AudioRecorder + 5-second
/// timer + WAV parse) and `TtsScreen` for playback (AudioConverter.pcmToWav +
/// just_audio), and wires both through one [VoiceSession.fromChat] built
/// from the three models chosen upstream in `VoiceSetupScreen` and passed in:
/// [VoiceScreen.sttModel], [VoiceScreen.llmModel] (a text-only chat model —
/// no tools, since `VoiceSession.fromChat` requires `chat.tools.isEmpty`) and
/// [VoiceScreen.ttsModel]. The upstream defaults reproduce the original trio
/// (Moonshine Tiny / Gemma 3 1B IT / Inflect-Nano-v2).
class VoiceScreen extends StatefulWidget {
  final SttModel sttModel;
  final Model llmModel;
  final TtsModel ttsModel;

  const VoiceScreen({
    super.key,
    required this.sttModel,
    required this.llmModel,
    required this.ttsModel,
  });

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  SpeechRecognizer? _recognizer;
  SpeechSynthesizer? _synth;
  InferenceChat? _chat;
  VoiceSession? _session;

  bool _isInitializing = true;
  String? _initError;
  String _stage = 'Downloading speech model';
  int? _downloadPercent;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final _player = AudioPlayer();

  bool _isRecording = false;
  // Reentrancy guards for the async gap BEFORE _isRecording/_turnRunning flip
  // true (a rapid double-tap during permission/IO would otherwise start two
  // overlapping operations). Not UI state — plain guards.
  bool _startingRecording = false;
  bool _startingBundledClip = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  static const _maxRecordingDuration = Duration(seconds: 5);

  bool _turnRunning = false;
  String? _transcript;
  String _replyText = '';
  String? _turnError;

  @override
  void initState() {
    super.initState();
    _initializeVoiceSession();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _player.dispose();
    _recognizer?.close();
    _synth?.close();
    _chat?.close();
    super.dispose();
  }

  /// Install (idempotent) + activate STT, TTS and the LLM chat, then build
  /// the [VoiceSession]. Mirrors `SttScreen._initializeSttModel` /
  /// `TtsScreen._initializeTtsModel`.
  Future<void> _initializeVoiceSession() async {
    // These are promoted to the state fields only in the terminal setState
    // below; until then dispose() can't reclaim them, so an early return / a
    // failure must close whatever was already activated — otherwise the
    // STT/TTS/LLM sessions leak on every failed init and retry.
    SpeechRecognizer? recognizer;
    SpeechSynthesizer? synth;
    InferenceChat? chat;
    Future<void> closePartial() async {
      await recognizer?.close();
      await synth?.close();
      await chat?.close();
    }

    try {
      // --- STT ---
      final sttToken = widget.sttModel.needsAuth
          ? await AuthTokenService.loadToken()
          : null;
      if (!mounted) return;
      setState(() {
        _stage = 'Downloading speech model';
        _downloadPercent = null;
      });
      await FlutterGemma.installStt()
          .modelFromNetwork(widget.sttModel.modelUrl, token: sttToken)
          .tokenizerFromNetwork(widget.sttModel.tokenizerUrl, token: sttToken)
          .ofType(widget.sttModel.sttModelType)
          .withModelProgress((percent) {
            if (!mounted) return;
            setState(() => _downloadPercent = percent);
          })
          .withTokenizerProgress((percent) {
            if (!mounted) return;
            setState(() => _downloadPercent = percent);
          })
          .install();
      recognizer = await FlutterGemma.getActiveStt();

      // --- TTS ---
      if (!mounted) {
        await closePartial();
        return;
      }
      setState(() {
        _stage = 'Downloading voice model';
        _downloadPercent = null;
      });
      await FlutterGemma.installTts()
          .fromNetwork(widget.ttsModel.baseUrl)
          .ofType(widget.ttsModel.ttsModelType)
          .withProgress((percent) {
            if (!mounted) return;
            setState(() => _downloadPercent = percent);
          })
          .install();
      synth = await FlutterGemma.getActiveTts();

      // --- LLM (no tools — see class doc) ---
      String? llmToken;
      if (widget.llmModel.needsAuth) {
        llmToken = await AuthTokenService.loadToken();
      }
      if (!mounted) {
        await closePartial();
        return;
      }
      setState(() {
        _stage = 'Downloading language model';
        _downloadPercent = null;
      });
      await FlutterGemma.installModel(
        modelType: widget.llmModel.modelType,
        fileType: widget.llmModel.fileType,
      ).fromNetwork(widget.llmModel.url, token: llmToken).withProgress((
        percent,
      ) {
        if (!mounted) return;
        setState(() => _downloadPercent = percent);
      }).install();

      final model = await FlutterGemma.getActiveModel(
        maxTokens: widget.llmModel.maxTokens,
        preferredBackend: widget.llmModel.preferredBackend,
      );
      chat = await model.createChat(
        temperature: widget.llmModel.temperature,
        randomSeed: 1,
        topK: widget.llmModel.topK,
        topP: widget.llmModel.topP,
        tokenBuffer: 256,
        tools: const [],
        modelType: widget.llmModel.modelType,
        maxOutputTokens: 128,
        systemInstruction:
            'Reply concisely in one or two short sentences; your reply will '
            'be spoken aloud.',
      );

      final session = VoiceSession.fromChat(
        recognizer: recognizer,
        chat: chat,
        synthesizer: synth,
      );

      if (!mounted) {
        await closePartial();
        return;
      }
      setState(() {
        _recognizer = recognizer;
        _synth = synth;
        _chat = chat;
        _session = session;
        _isInitializing = false;
      });
    } catch (e) {
      // Close whatever activated before the failure (dispose() only reclaims
      // resources once they've been promoted to the state fields).
      await closePartial();
      if (kDebugMode) {
        debugPrint('[VoiceScreen] Could not initialize voice session: $e');
      }
      if (!mounted) return;
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
    }
  }

  Future<void> _runTurn(Uint8List pcm16kMono) async {
    final session = _session;
    if (session == null || _turnRunning) return; // reentrancy guard
    setState(() {
      _turnRunning = true;
      _transcript = null;
      _replyText = '';
      _turnError = null;
    });
    try {
      await for (final event in session.runTurn(pcm16kMono)) {
        switch (event) {
          case VoiceTranscriptEvent(:final text):
            if (!mounted) return;
            setState(() => _transcript = text);
            break;
          case VoiceReplyTextEvent(:final chunk):
            if (!mounted) return;
            setState(() => _replyText += chunk);
            break;
          case VoiceReplyAudioEvent(:final pcm, :final sampleRate):
            await _playReply(pcm, sampleRate);
            break;
          case VoiceTurnInterruptedEvent():
            await _player.stop();
            break;
          case VoiceTurnCompleteEvent():
          case VoiceErrorEvent():
            break;
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _turnError = e.toString());
    } finally {
      if (mounted) setState(() => _turnRunning = false);
    }
  }

  /// WAV-wrap the synthesized reply PCM and play it via just_audio. Mirrors
  /// `TtsScreen._speak`'s playback tail (temp file -> setFilePath -> play).
  Future<void> _playReply(Uint8List pcm, int sampleRate) async {
    final wav = AudioConverter.pcmToWav(pcm, sampleRate: sampleRate);
    final dir = await getTemporaryDirectory();
    if (!mounted) return;
    final file = createFile('${dir.path}/voice_reply.wav');
    await file.writeAsBytes(wav);
    if (!mounted) return;
    await _player.setFilePath(file.path);
    await _player.play();
  }

  /// Barge-in: stop the in-flight turn (the player is also stopped by the
  /// resulting [VoiceTurnInterruptedEvent] handled in [_runTurn], for the
  /// mid-generation case). `interrupt()` is a documented no-op once the reply
  /// has already reached playback (v1 emits its one final audio event +
  /// Complete before playback finishes), so stop the player explicitly here
  /// too — that's what actually cuts the audio during that case. Idempotent
  /// — a no-op when no turn is running.
  Future<void> _bargeIn() async {
    await _session?.interrupt();
    await _player.stop();
  }

  Future<void> _runBundledClip() async {
    if (_turnRunning || _startingBundledClip) return; // guard the load gap
    _startingBundledClip = true;
    try {
      final data = await rootBundle.load('assets/test/test_audio.wav');
      final wavBytes = data.buffer.asUint8List();
      final parsed = AudioConverter.parseWav(wavBytes);
      final pcm = AudioConverter.toPCM16kHzMono(
        parsed.pcmData,
        sourceSampleRate: parsed.sampleRate,
        sourceChannels: parsed.channels,
      );
      await _runTurn(pcm);
    } catch (e) {
      if (!mounted) return;
      setState(() => _turnError = e.toString());
    } finally {
      _startingBundledClip = false;
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecordingAndRunTurn();
    } else {
      if (_startingRecording) return; // guard the start-up async gap
      _startingRecording = true;
      try {
        await _startRecording();
      } finally {
        _startingRecording = false;
      }
    }
  }

  Future<void> _startRecording() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    if (!kIsWeb && (platformIsAndroid || platformIsIOS)) {
      final status = await Permission.microphone.request();
      if (!mounted) {
        return; // a permission dialog is a classic navigate-away gap
      }
      if (!status.isGranted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required for recording'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (!await _audioRecorder.hasPermission()) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Microphone not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: kIsWeb ? '' : '$systemTempPath/voice_recording.wav',
      );

      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
        _transcript = null;
        _replyText = '';
        _turnError = null;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => _recordingDuration += const Duration(seconds: 1));
        if (_recordingDuration >= _maxRecordingDuration) {
          _stopRecordingAndRunTurn();
        }
      });
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to start recording: $e')),
      );
    }
  }

  Future<void> _stopRecordingAndRunTurn() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      final path = await _audioRecorder.stop();
      if (!mounted) return;
      setState(() => _isRecording = false);
      if (path == null) return;

      Uint8List wavBytes;
      if (kIsWeb) {
        final response = await http.get(Uri.parse(path));
        wavBytes = response.bodyBytes;
      } else {
        final file = createFile(path);
        wavBytes = await file.readAsBytes();
        await file.delete();
      }

      final parsed = AudioConverter.parseWav(wavBytes);
      final pcm = AudioConverter.toPCM16kHzMono(
        parsed.pcmData,
        sourceSampleRate: parsed.sampleRate,
        sourceChannels: parsed.channels,
      );
      await _runTurn(pcm);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRecording = false);
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to save recording: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Voice Loop'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildModelInfoCard(),
            const SizedBox(height: 24),
            if (_isInitializing) _buildInitializingState(),
            if (!_isInitializing && _initError != null) _buildInitError(),
            if (!_isInitializing && _initError == null) ...[
              _buildActions(),
              const SizedBox(height: 24),
              _buildResults(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModelInfoCard() {
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Voice Loop (STT -> LLM -> TTS)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('STT:', widget.sttModel.displayName),
            _buildInfoRow('LLM:', widget.llmModel.displayName),
            _buildInfoRow('TTS:', widget.ttsModel.displayName),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitializingState() {
    final percent = _downloadPercent;
    final showPercent = percent != null && percent < 100;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32.0),
        child: Column(
          children: [
            CircularProgressIndicator(
              color: Colors.blue,
              value: showPercent ? percent / 100.0 : null,
            ),
            const SizedBox(height: 16),
            Text(
              showPercent
                  ? '$_stage… $percent%'
                  : 'Installing models and preparing the voice session…',
              style: const TextStyle(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInitError() {
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Failed to prepare the voice session',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _initError!,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Talk',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: (_turnRunning || _isRecording)
                    ? null
                    : _runBundledClip,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1a4a7c),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Run Bundled Clip'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _turnRunning ? null : _toggleRecording,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(
                  _isRecording
                      ? 'Stop (${_recordingDuration.inSeconds}s)'
                      : 'Record & Run Turn',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRecording
                      ? Colors.red
                      : const Color(0xFF2a5a8c),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _turnRunning ? _bargeIn : null,
            icon: const Icon(Icons.front_hand),
            label: const Text('Stop / Barge-in'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              side: const BorderSide(color: Colors.orangeAccent),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    return SizedBox(
      height: 280,
      child: Card(
        color: const Color(0xFF1a3a5c),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Turn Log',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildResultsContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultsContent() {
    if (_turnError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _turnError!,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_transcript == null && _replyText.isEmpty && !_turnRunning) {
      return const Center(
        child: Text(
          'Run the bundled clip or record your own to hear a reply.',
          style: TextStyle(color: Colors.white60, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_turnRunning) ...[
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue,
                  ),
                ),
                SizedBox(width: 12),
                Text('Running turn…', style: TextStyle(color: Colors.white60)),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_transcript != null) ...[
            const Text(
              'You said:',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            Text(
              _transcript!.isEmpty ? '(empty transcript)' : _transcript!,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 16),
          ],
          if (_replyText.isNotEmpty) ...[
            const Text(
              'Reply:',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            Text(
              _replyText,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ],
      ),
    );
  }
}
