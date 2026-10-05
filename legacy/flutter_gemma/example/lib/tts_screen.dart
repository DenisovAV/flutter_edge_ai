import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/tts_model.dart';
import 'package:flutter_gemma_example/utils/audio_converter.dart';
import 'package:flutter_gemma_example/utils/platform_io_helper.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart'
    show qwen3SupportedLanguages;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// TTS synthesize screen — mirrors [SttScreen]'s install-in-initState /
/// `mounted`-after-await / reentrancy discipline, but the flow is simpler:
/// no recording, just a text field → synthesize → play. Installs
/// (idempotent) and activates [widget.model] (chosen upstream in
/// [TtsModelsScreen]) then lets the user type text and hear it spoken via
/// [SpeechSynthesizer.synthesize] + `just_audio` playback of the
/// WAV-wrapped PCM (`AudioConverter.pcmToWav`).
///
/// [TtsModel.qwen3] additionally exposes a LANGUAGE dropdown (11 languages,
/// populated from `qwen3SupportedLanguages` — see Task 5.4's brief for why
/// language, not voice, is the v1-selectable dimension: the model ships
/// exactly one voice, no voice picker). Language is a create-time param
/// (`FlutterGemma.getActiveTts(language: ...)`) — changing it re-creates the
/// synthesizer (closes the old one, installs/activates again), reloading
/// the ~1.9 GB model.
///
/// `createFile` (not raw `dart:io`) is used to write the WAV to a temp file
/// so this screen still compiles for web, where `flutter_gemma_speech` has
/// no TTS arm (the init call surfaces that as [_initError] instead).
class TtsScreen extends StatefulWidget {
  final TtsModel model;

  const TtsScreen({super.key, required this.model});

  @override
  State<TtsScreen> createState() => _TtsScreenState();
}

class _TtsScreenState extends State<TtsScreen> {
  late final TtsModel _model = widget.model;
  String _language = 'english';

  SpeechSynthesizer? _synth;
  bool _isInitializing = true;
  String? _initError;
  int? _downloadPercent;

  final _textController = TextEditingController(text: 'Hello world.');
  final _player = AudioPlayer();

  bool _isSpeaking = false;
  String? _speakError;

  @override
  void initState() {
    super.initState();
    _initializeTtsModel();
  }

  @override
  void dispose() {
    _textController.dispose();
    _player.dispose();
    _synth?.close();
    super.dispose();
  }

  bool get _isQwen3 => _model.ttsModelType == TtsModelType.qwen3;

  /// Install (idempotent) + activate [_model], then create the
  /// [SpeechSynthesizer]. Mirrors `SttScreen._initializeSttModel`.
  ///
  /// Closes any previously-created [_synth] first — `getActiveTts` reuses a
  /// singleton for the same active model, so a language change alone (same
  /// [_model], new [_language]) would otherwise silently keep serving the
  /// OLD language unless the old instance is closed first (see
  /// `FlutterGemma.getActiveTts`'s doc).
  Future<void> _initializeTtsModel() async {
    setState(() {
      _isInitializing = true;
      _initError = null;
      _downloadPercent = null;
    });
    final oldSynth = _synth;
    _synth = null;
    await oldSynth?.close();
    try {
      await FlutterGemma.installTts()
          .fromNetwork(_model.baseUrl)
          .ofType(_model.ttsModelType)
          .withProgress((percent) {
            if (!mounted) return;
            setState(() => _downloadPercent = percent);
          })
          .install();

      final synth = await FlutterGemma.getActiveTts(
        language: _isQwen3 ? _language : null,
      );

      if (!mounted) return;
      setState(() {
        _synth = synth;
        _isInitializing = false;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TtsScreen] Could not initialize TTS model: $e');
      }
      if (!mounted) return;
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
    }
  }

  /// Switch the qwen3 language and reinitialize (see [_initializeTtsModel]'s
  /// doc for why this must close+recreate rather than just updating state).
  void _selectLanguage(String language) {
    if (language == _language || _isInitializing) return;
    setState(() => _language = language);
    _initializeTtsModel();
  }

  Future<void> _speak() async {
    if (_synth == null || _isSpeaking) return; // reentrancy guard
    setState(() {
      _isSpeaking = true;
      _speakError = null;
    });
    try {
      final pcm = await _synth!.synthesize(_textController.text);
      if (!mounted) return;

      final wav = AudioConverter.pcmToWav(pcm, sampleRate: _synth!.sampleRate);
      final tempDir = await getTemporaryDirectory();
      if (!mounted) return;

      final file = createFile('${tempDir.path}/tts_output.wav');
      await file.writeAsBytes(wav);
      if (!mounted) return;

      await _player.setFilePath(file.path);
      await _player.play();

      if (!mounted) return;
      setState(() => _isSpeaking = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speakError = e.toString();
        _isSpeaking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: Text(_model.displayName),
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
            if (!_isInitializing && _initError == null) _buildSpeakSection(),
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
            _buildInfoRow('Model:', _model.displayName),
            _buildInfoRow('Size:', _model.size),
            _buildInfoRow('Type:', 'Text-to-Speech'),
            if (_isQwen3) ...[
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                label: 'Language:',
                value: _language,
                items: [
                  for (final lang in qwen3SupportedLanguages)
                    DropdownMenuItem(value: lang, child: Text(lang)),
                ],
                onChanged: (lang) {
                  if (lang != null) _selectLanguage(lang);
                },
              ),
            ],
            if (_model.notes != null) ...[
              const SizedBox(height: 12),
              Text(
                _model.notes!,
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A label + [DropdownButton] row, disabled while [_isInitializing] (a
  /// language switch is already in flight — reentrancy guard mirrors
  /// [_selectLanguage]'s own check).
  Widget _buildDropdownRow<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          child: DropdownButton<T>(
            value: value,
            items: items,
            onChanged: _isInitializing ? null : onChanged,
            isExpanded: true,
            dropdownColor: const Color(0xFF1a3a5c),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
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
                  ? 'Downloading model… $percent%'
                  : 'Installing model and preparing synthesizer…',
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
              'Failed to prepare the TTS model',
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

  Widget _buildSpeakSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Synthesize',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _textController,
          maxLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Text to speak',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF1a3a5c),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isSpeaking ? null : _speak,
            icon: Icon(_isSpeaking ? Icons.volume_up : Icons.play_arrow),
            label: Text(_isSpeaking ? 'Speaking…' : 'Speak'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2a5a8c),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (_speakError != null) ...[
          const SizedBox(height: 16),
          Text(
            _speakError!,
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
