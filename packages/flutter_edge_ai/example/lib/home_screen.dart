import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai_example/agent_demo_screen.dart';
import 'package:flutter_edge_ai_example/downloaded_models_screen.dart';
import 'package:flutter_edge_ai_example/embedding_models_screen.dart';
import 'package:flutter_edge_ai_example/image_search_screen.dart';
import 'package:flutter_edge_ai_example/multimodal_rag_screen.dart';
import 'package:flutter_edge_ai_example/model_selection_screen.dart';
import 'package:flutter_edge_ai_example/stt_models_screen.dart';
import 'package:flutter_edge_ai_example/tiny_island/tiny_island_platform.dart';
import 'package:flutter_edge_ai_example/tiny_island_screen.dart';
import 'package:flutter_edge_ai_example/translate_models_screen.dart';
import 'package:flutter_edge_ai_example/tts_models_screen.dart';
import 'package:flutter_edge_ai_example/utils/installed_model_lookup.dart';
import 'package:flutter_edge_ai_example/voice_setup_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _downloadCheckComplete = false;
  bool _hasDownloadedModels = false;

  @override
  void initState() {
    super.initState();
    _refreshDownloadedVisibility();
  }

  Future<void> _refreshDownloadedVisibility() async {
    final hasDownloaded = await hasDownloadedModels();
    if (!mounted) return;
    setState(() {
      _hasDownloadedModels = hasDownloaded;
      _downloadCheckComplete = true;
    });
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (context) => screen),
    );
    await _refreshDownloadedVisibility();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Flutter Edge AI Example'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            const Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: Colors.white,
            ),
            const SizedBox(height: 32),
            const Text(
              'Welcome to Flutter Edge AI',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'Explore powerful AI models including Gemma 3 Nano running directly on your device',
              style: TextStyle(fontSize: 16, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 48),
            if (_downloadCheckComplete && _hasDownloadedModels) ...[
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 12),
                child: Text(
                  'On this device',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              _NavigationCard(
                title: 'Downloaded Models',
                subtitle:
                    'View installed inference, translation, and embedding models',
                icon: Icons.folder_open,
                color: Colors.teal,
                onTap: () => _push(const DownloadedModelsScreen()),
              ),
              const SizedBox(height: 32),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 16),
            ],
            _NavigationCard(
              title: 'Inference Models',
              subtitle: 'Browse and test all available Gemma models',
              icon: Icons.model_training,
              color: Colors.blue,
              onTap: () => _push(const ModelSelectionScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Translation Models',
              subtitle: 'On-device translation with TranslateGemma',
              icon: Icons.translate,
              color: Colors.orange,
              onTap: () => _push(const TranslateModelsScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Embedding Models',
              subtitle: 'Download and test embedding models for RAG',
              icon: Icons.search,
              color: Colors.green,
              onTap: () => _push(const EmbeddingModelsScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              key: const Key('home-image-search'),
              title: 'Image Search',
              subtitle:
                  'Find photos by text or by photo with EmbeddingGemma 2 '
                  '(choose Text + Vision 440M under Embedding Models)',
              icon: Icons.image_search,
              color: Colors.lightGreen,
              onTap: () => _push(const ImageSearchScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              key: const Key('home-multimodal-rag'),
              title: 'Multimodal RAG',
              subtitle:
                  'Find notes, photos and voice memos by meaning, hear a '
                  'meeting live, ask Gemma 4 — EmbeddingGemma 2 and Gemma 4, '
                  'all on the device',
              icon: Icons.hub_outlined,
              color: Colors.indigoAccent,
              onTap: () => _push(const MultimodalRagScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              key: const Key('home-tiny-island'),
              title: 'Tiny Island',
              subtitle:
                  tinyIslandUnsupportedReason() ??
                  'Control a 3D scene with words; EmbeddingGemma 2 decides '
                      '(choose Text 270M under Embedding Models, or '
                      'Text + Vision + Audio 740M to speak to it)',
              icon: Icons.landscape,
              color: Colors.cyan,
              onTap: tinyIslandUnsupportedReason() == null
                  ? () => _push(const TinyIslandScreen())
                  : null,
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Speech-to-Text',
              subtitle: 'On-device transcription with Moonshine',
              icon: Icons.mic,
              color: Colors.pink,
              onTap: () => _push(const SttModelsScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Text-to-Speech',
              subtitle: 'On-device speech synthesis with Matcha & Qwen3',
              icon: Icons.volume_up,
              color: Colors.deepPurple,
              onTap: () => _push(const TtsModelsScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Voice Loop',
              subtitle: 'Speak → on-device STT → LLM → TTS → hear the reply',
              icon: Icons.record_voice_over,
              color: Colors.teal,
              onTap: () => _push(const VoiceSetupScreen()),
            ),
            const SizedBox(height: 16),
            _NavigationCard(
              title: 'Agent Skills',
              subtitle: kIsWeb
                  ? 'On-device agent (Android / iOS / desktop — not on web yet)'
                  : 'On-device agent with bundled SKILL.md skills',
              icon: Icons.auto_awesome,
              color: Colors.purple,
              onTap: () => _push(const AgentDemoScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationCard extends StatelessWidget {
  const _NavigationCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  /// Null shows the card disabled: its subtitle then says why.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Card(
      color: enabled ? const Color(0xFF1a3a5c) : const Color(0xFF15283d),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: enabled ? color : Colors.white38,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: enabled ? null : Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              if (enabled)
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white54,
                  size: 16,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
