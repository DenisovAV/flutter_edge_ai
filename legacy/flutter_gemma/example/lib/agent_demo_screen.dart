import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_agent/flutter_gemma_agent.dart';
import 'package:flutter_gemma_example/loading_widget.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/universal_download_screen.dart';

/// Demonstrates `flutter_gemma_agent`: the bundled starter skills (ported from
/// google-ai-edge/gallery, Apache-2.0) driving a Gemma 4 model through the
/// agentic tool-calling loop.
///
/// Downloading is delegated to the shared [UniversalDownloadScreen] (info card +
/// token/license + a real progress bar), reused via its `onReady` callback. Once
/// the model is installed, this screen loads the bundled SKILL.md skills via
/// [AssetSkillSource] and mounts [AgentChatView] over an [AgentSession]; the
/// executors (text / JS / native-intent) were registered globally in
/// `bootstrapGemma` via `FlutterGemma.initialize(skillExecutors: …)`.
class AgentDemoScreen extends StatefulWidget {
  const AgentDemoScreen({super.key});

  @override
  State<AgentDemoScreen> createState() => _AgentDemoScreenState();
}

class _AgentDemoScreenState extends State<AgentDemoScreen> {
  /// The models suitable for the agent loop (curated `agentic: true`), falling
  /// back to any function-calling model so the screen never crashes on an empty
  /// filter (e.g. if the flags are ever removed).
  static final _agentModels = () {
    final agentic = Model.values.where((m) => m.agentic).toList();
    if (agentic.isNotEmpty) return agentic;
    return Model.values.where((m) => m.supportsFunctionCalls).toList();
  }();

  Model _model = _agentModels.first;

  AgentSession? _session;
  bool _loading = false;
  String? _error;
  String _status = '';

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  /// Open the shared download screen for the selected model. On Continue it
  /// pops back to THIS screen (keeping a single AgentDemoScreen in the stack, so
  /// the back button returns to Home — not to a stale intro), and we build the
  /// session in place.
  Future<void> _openDownloadScreen() async {
    final ready = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => UniversalDownloadScreen(
          model: _model,
          onReady: (ctx) => Navigator.of(ctx).pop(true),
        ),
      ),
    );
    if (ready == true && mounted) {
      await _buildSession();
    }
  }

  /// The model is installed — load it, load the skills, build the session.
  Future<void> _buildSession() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Loading model…';
    });

    try {
      final model = await FlutterGemma.getActiveModel(
        maxTokens: _model.maxTokens,
        preferredBackend: _model.preferredBackend,
      );
      if (!mounted) return;

      setState(() => _status = 'Loading skills…');
      final skills = await AssetSkillSource().load();
      final registry = SkillRegistry()..addAll(skills, selected: true);

      // No `executors:` here: the text / JS / native-intent executors were
      // registered globally in `bootstrapGemma` via
      // `FlutterGemma.initialize(skillExecutors: …)`, so `fromModel` reads them
      // from the core registry (the recommended path). To override for one
      // session, pass an explicit list:
      //   executors: [TextSkillExecutor(), JsSkillExecutor(sourceFor: …), …]
      final session = await AgentSession.fromModel(
        model,
        registry: registry,
        temperature: _model.temperature,
        topK: _model.topK,
        topP: _model.topP,
      );

      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Agent Skills'),
        backgroundColor: const Color(0xFF0b2351),
        foregroundColor: Colors.white,
        actions: [
          // The adaptive skill manager (bottom sheet on phones, side panel on
          // wide windows). It toggles the live session registry, so enabling /
          // disabling a skill takes effect on the agent's next turn.
          if (_session != null)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Manage skills',
              onPressed: () => SkillManagerView.showAdaptive(
                context,
                registry: _session!.registry,
                secretStore: _session!.secretStore,
              ),
            ),
        ],
      ),
      body: _session != null
          ? AgentChatView(
              session: _session!,
              hintText:
                  'e.g. "Calculate the hash of hello" or '
                  '"Show Paris on interactive map"',
            )
          : _buildIntro(context),
    );
  }

  Widget _buildIntro(BuildContext context) {
    if (_loading) {
      return LoadingWidget(message: _status);
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1a3a5c),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 56,
                  color: Colors.purpleAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  'On-device agent skills',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Loads the bundled starter skills (calculate-hash, qr-code, '
                  'query-wikipedia, interactive-map, send-email, '
                  'create-calendar-event, get-current-time, kitchen-adventure) '
                  'and lets ${_model.displayName} call them through the '
                  'tool-calling loop.',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Downloads ${_model.size}. Requires GPU/CPU as available.',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.4),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.block, color: Colors.redAccent, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'The agent is not supported on web yet. The browser LLM '
                      'runtime does not reliably emit tool calls, so skills '
                      'don\'t run end-to-end. Use Android, iOS, macOS, or '
                      'Windows for the agent.',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 24),
          // Model picker + Start button — hidden on web (agent unsupported).
          if (!kIsWeb && _agentModels.length > 1) ...[
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                'Model',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1a3a5c),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButton<Model>(
                value: _model,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: const Color(0xFF1a3a5c),
                iconEnabledColor: Colors.white70,
                style: const TextStyle(color: Colors.white),
                items: [
                  for (final m in _agentModels)
                    DropdownMenuItem<Model>(
                      value: m,
                      child: Text('${m.displayName}  ·  ${m.size}'),
                    ),
                ],
                onChanged: (m) {
                  if (m != null) setState(() => _model = m);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (!kIsWeb)
            ElevatedButton.icon(
              onPressed: _openDownloadScreen,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start agent'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purpleAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
        ],
      ),
    );
  }
}
