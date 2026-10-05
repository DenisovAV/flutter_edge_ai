import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/model_selection_screen.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/stt_model.dart';
import 'package:flutter_gemma_example/models/tts_model.dart';
import 'package:flutter_gemma_example/stt_models_screen.dart';
import 'package:flutter_gemma_example/tts_models_screen.dart';
import 'package:flutter_gemma_example/voice_screen.dart';

/// Voice Loop setup — pick the model for each of the three pipeline steps
/// (STT -> LLM -> TTS) via the standard per-modality list screens, then start
/// the loop. Mirrors how model selection works everywhere else in the example
/// (Inference / STT / TTS / Translate): selection lives in a list screen, not
/// an in-screen dropdown. Each row pushes the matching selection screen
/// (`SttModelsScreen` / `ModelSelectionScreen` / `TtsModelsScreen`) in
/// selection mode (its `onSelected` callback); for STT/TTS only entries with a
/// shipped profile are pickable, whereas any LLM is pickable. Defaults
/// reproduce the previously-hardcoded trio (Moonshine Tiny / Gemma 3 1B IT /
/// Inflect-Nano-v2), so the loop's behaviour is unchanged until the user swaps a
/// step.
class VoiceSetupScreen extends StatefulWidget {
  const VoiceSetupScreen({super.key});

  @override
  State<VoiceSetupScreen> createState() => _VoiceSetupScreenState();
}

class _VoiceSetupScreenState extends State<VoiceSetupScreen> {
  SttModel _stt = SttModel.moonshineTiny;
  Model _llm = Model.gemma3_1B;
  TtsModel _tts = TtsModel.inflect;

  Future<void> _pickStt() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) =>
          SttModelsScreen(onSelected: (m) => setState(() => _stt = m)),
    ),
  );

  Future<void> _pickLlm() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ModelSelectionScreen(
        // The loop installs the LLM via installModel(...).fromNetwork(url), so
        // offer only network-installable models: no OS built-ins (no file) and
        // no localModel asset entries (their url is an assets/... path).
        modelFilter: (m) => !m.isBuiltIn && !m.localModel,
        onSelected: (m) => setState(() => _llm = m),
      ),
    ),
  );

  Future<void> _pickTts() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) =>
          TtsModelsScreen(onSelected: (m) => setState(() => _tts = m)),
    ),
  );

  void _start() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            VoiceScreen(sttModel: _stt, llmModel: _llm, ttsModel: _tts),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Voice Loop'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pick a model for each step',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'STT → LLM → TTS. Tap a step to choose its model, then start the '
              'loop.',
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 24),
            Card(
              color: const Color(0xFF1a3a5c),
              child: Column(
                children: [
                  _stepRow('STT', _stt.displayName, _pickStt),
                  const Divider(height: 1, color: Colors.white12),
                  _stepRow('LLM', _llm.displayName, _pickLlm),
                  const Divider(height: 1, color: Colors.white12),
                  _stepRow('TTS', _tts.displayName, _pickTts),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Voice Loop'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2a5a8c),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(String step, String modelName, VoidCallback onTap) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 44,
        child: Text(
          step,
          style: const TextStyle(
            color: Colors.white70,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        modelName,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Icon(
        Icons.arrow_forward_ios,
        size: 16,
        color: Colors.grey[400],
      ),
      onTap: onTap,
    );
  }
}
