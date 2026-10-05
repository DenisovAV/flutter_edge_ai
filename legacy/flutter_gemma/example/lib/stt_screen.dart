import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/stt_model.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/utils/audio_converter.dart';
import 'package:flutter_gemma_example/utils/platform_io_helper.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// STT transcribe screen — mirrors `EmbeddingTestScreen`. Installs the
/// selected [SttModel] (idempotent — skips download if already installed)
/// and sets it active in [initState], then lets the user transcribe either
/// the bundled test clip or a freshly recorded one via [SpeechRecognizer].
class SttScreen extends StatefulWidget {
  final SttModel model;

  const SttScreen({super.key, required this.model});

  @override
  State<SttScreen> createState() => _SttScreenState();
}

class _SttScreenState extends State<SttScreen> {
  SpeechRecognizer? _recognizer;
  bool _isInitializing = true;
  String? _initError;
  int? _downloadPercent;

  /// Which file the percentage refers to. The model and the tokenizer are
  /// downloaded sequentially into the same counter, so without this the bar
  /// runs 0→100→0 and the label lies during the second phase.
  String _downloadStage = 'model';

  bool _isTranscribing = false;
  String? _transcript;
  String? _transcribeError;

  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  // Reentrancy guards for the async gap BEFORE _isRecording/_isTranscribing
  // flip true (a rapid double-tap during permission/IO would otherwise start
  // two overlapping operations). Not UI state — plain guards.
  bool _startingRecording = false;
  bool _startingTranscribe = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  static const _maxRecordingDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _initializeSttModel();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _recognizer?.close();
    super.dispose();
  }

  /// Install (idempotent) + activate the selected model, then create the
  /// [SpeechRecognizer]. Mirrors `EmbeddingTestScreen._initializeEmbeddingModelIfNeeded`.
  Future<void> _initializeSttModel() async {
    try {
      String? token;
      if (widget.model.needsAuth) {
        token = await AuthTokenService.loadToken();
      }

      await FlutterGemma.installStt()
          .modelFromNetwork(widget.model.modelUrl, token: token)
          .tokenizerFromNetwork(widget.model.tokenizerUrl, token: token)
          .ofType(widget.model.sttModelType)
          .withModelProgress((percent) {
            if (!mounted) return;
            setState(() {
              _downloadStage = 'model';
              _downloadPercent = percent;
            });
          })
          .withTokenizerProgress((percent) {
            if (!mounted) return;
            setState(() {
              _downloadStage = 'tokenizer';
              _downloadPercent = percent;
            });
          })
          .install();

      final recognizer = await FlutterGemma.getActiveStt();

      if (!mounted) return;
      setState(() {
        _recognizer = recognizer;
        _isInitializing = false;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SttScreen] Could not initialize STT model: $e');
      }
      if (!mounted) return;
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
    }
  }

  Future<void> _transcribe(Uint8List pcm16kMono) async {
    if (_recognizer == null) return;
    if (!mounted) return; // callers await audio decode/IO before reaching here
    setState(() {
      _isTranscribing = true;
      _transcribeError = null;
      _transcript = null;
    });
    try {
      final text = await _recognizer!.transcribe(pcm16kMono);
      if (!mounted) return;
      setState(() {
        _transcript = text;
        _isTranscribing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transcribeError = e.toString();
        _isTranscribing = false;
      });
    }
  }

  Future<void> _transcribeBundledClip() async {
    if (_isTranscribing || _startingTranscribe) return; // guard the load gap
    _startingTranscribe = true;
    try {
      final data = await rootBundle.load('assets/test/test_audio.wav');
      final wavBytes = data.buffer.asUint8List();
      final parsed = AudioConverter.parseWav(wavBytes);
      final pcm = AudioConverter.toPCM16kHzMono(
        parsed.pcmData,
        sourceSampleRate: parsed.sampleRate,
        sourceChannels: parsed.channels,
      );
      await _transcribe(pcm);
    } catch (e) {
      if (!mounted) return;
      setState(() => _transcribeError = e.toString());
    } finally {
      _startingTranscribe = false;
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecordingAndTranscribe();
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
      if (!mounted)
        return; // a permission dialog is a classic navigate-away gap
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
        path: kIsWeb ? '' : '$systemTempPath/stt_recording.wav',
      );

      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
        _transcript = null;
        _transcribeError = null;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => _recordingDuration += const Duration(seconds: 1));
        if (_recordingDuration >= _maxRecordingDuration) {
          _stopRecordingAndTranscribe();
        }
      });
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to start recording: $e')),
      );
    }
  }

  Future<void> _stopRecordingAndTranscribe() async {
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
      await _transcribe(pcm);
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
        title: Text(widget.model.displayName),
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
              'Model Information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Size:', widget.model.size),
            _buildInfoRow('Type:', 'Speech-to-Text'),
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
                  ? 'Downloading $_downloadStage… $percent%'
                  : 'Installing model and preparing recognizer…',
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
              'Failed to prepare the STT model',
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
          'Transcribe',
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
                onPressed: (_isTranscribing || _isRecording)
                    ? null
                    : _transcribeBundledClip,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1a4a7c),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Transcribe Bundled Clip'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isTranscribing ? null : _toggleRecording,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(
                  _isRecording
                      ? 'Stop (${_recordingDuration.inSeconds}s)'
                      : 'Record & Transcribe',
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
      ],
    );
  }

  Widget _buildResults() {
    return SizedBox(
      height: 240,
      child: Card(
        color: const Color(0xFF1a3a5c),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Transcript',
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
    if (_isTranscribing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.blue),
            SizedBox(height: 16),
            Text('Transcribing…', style: TextStyle(color: Colors.white60)),
          ],
        ),
      );
    }

    if (_transcribeError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _transcribeError!,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_transcript != null) {
      return SingleChildScrollView(
        child: Text(
          _transcript!.isEmpty ? '(empty transcript)' : _transcript!,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    return const Center(
      child: Text(
        'Transcribe the bundled clip or record your own to see text here.',
        style: TextStyle(color: Colors.white60, fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }
}
