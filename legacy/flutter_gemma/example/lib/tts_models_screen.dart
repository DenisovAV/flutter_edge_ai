import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/models/tts_model.dart';
import 'package:flutter_gemma_example/tts_screen.dart';

/// TTS model selection screen — mirrors [SttModelsScreen]. Lists the
/// [TtsModel] catalog; picking a supported entry pushes [TtsScreen], which
/// installs it (idempotent) and sets it active — unless [onSelected] is set
/// (pick-a-model mode), which returns the choice and pops instead. Unsupported
/// entries (need
/// their own `TtsModelProfile`, see [TtsModel.unsupportedReason]) are shown
/// but disabled. Model selection lives here — the standard list screen —
/// not in an in-screen dropdown, so TTS matches STT / Inference / Translate.
class TtsModelsScreen extends StatelessWidget {
  /// When set, the screen is in "pick a model" mode: tapping a supported entry
  /// invokes this and pops (returning the choice to the caller, e.g.
  /// `VoiceSetupScreen`) instead of navigating into [TtsScreen].
  final ValueChanged<TtsModel>? onSelected;

  const TtsModelsScreen({super.key, this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Text-to-Speech Models'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'On-device Text-to-Speech',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Download a model and synthesize speech from text',
              style: TextStyle(fontSize: 16, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Expanded(
              child: ListView.builder(
                itemCount: TtsModel.values.length,
                itemBuilder: (context, index) {
                  final model = TtsModel.values[index];
                  return _TtsModelCard(model: model, onSelected: onSelected);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TtsModelCard extends StatelessWidget {
  final TtsModel model;
  final ValueChanged<TtsModel>? onSelected;

  const _TtsModelCard({required this.model, this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1a3a5c),
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16.0),
        enabled: model.isSupported,
        title: Text(
          model.displayName,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16.0,
            color: model.isSupported ? Colors.white : Colors.white38,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 4.0,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12.0),
                    ),
                    child: Text(
                      model.size,
                      style: TextStyle(
                        color: Colors.blue[200],
                        fontWeight: FontWeight.bold,
                        fontSize: 12.0,
                      ),
                    ),
                  ),
                  if (!model.isSupported) ...[
                    const SizedBox(width: 8.0),
                    Expanded(
                      child: Text(
                        model.unsupportedReason ?? 'Not supported yet',
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 12.0,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              // Performance/hardware caveat for supported models (e.g. qwen3's
              // CPU-only / RTF≈3 / 6 GB-RAM note) — mirrors the caveat the
              // [TtsScreen] model-info card shows once selected.
              if (model.isSupported && model.notes != null) ...[
                const SizedBox(height: 8.0),
                Text(
                  model.notes!,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12.0,
                  ),
                ),
              ],
            ],
          ),
        ),
        trailing: model.isSupported
            ? Icon(Icons.arrow_forward_ios, color: Colors.grey[400])
            : const Icon(Icons.lock_outline, color: Colors.white24),
        onTap: model.isSupported
            ? () {
                final cb = onSelected;
                if (cb != null) {
                  cb(model);
                  Navigator.pop(context);
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => TtsScreen(model: model),
                    ),
                  );
                }
              }
            : null,
      ),
    );
  }
}
