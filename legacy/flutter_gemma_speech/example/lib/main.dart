// Agentic voice loop demo for flutter_gemma_speech.
//
// One screen, two modes over the SAME on-device pipeline (STT → LLM → TTS):
//   • Tools  — VoiceSession.fromChat(onToolCall:): the LLM can call app tools
//              (get_current_time / show_alert) mid-turn; the app runs them and
//              the model speaks the result. Needs only flutter_gemma_speech +
//              flutter_gemma (core function-calling loop) + the litertlm engine.
//   • Agent  — VoiceSession.custom(responder: agentVoiceResponder(agent)): the
//              full flutter_gemma_agent drives skills (e.g. "calculate the hash
//              of hello" → the bundled calculate-hash JS skill) and the final
//              answer is spoken. The agent glue lives here in the app, so
//              flutter_gemma_speech never depends on flutter_gemma_agent.
//
// Speak by holding the mic button, or tap "Demo turn" to run the bundled clip
// (no microphone needed). The LLM (Gemma 4 E2B, .litertlm) loads from a
// device-local staged file when present, else downloads from HuggingFace with
// the token you enter. STT (Moonshine) and TTS (Inflect) are public downloads.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_agent/flutter_gemma_agent.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'agent_voice_responder.dart';
import 'audio_converter.dart';

// ── Models ──────────────────────────────────────────────────────────────────
const _sttModelUrl =
    'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite';
const _sttTokenizerUrl =
    'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json';
const _llmUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
const _llmFileName = 'gemma-4-E2B-it.litertlm';
const _ttsUrl =
    'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';

// flutter_gemma brand palette (matches the main example's screens).
const _kNavy = Color(0xFF0b2351);
const _kCard = Color(0xFF1a3a5c);
const _kAccent = Color(0xFF2a5a8c);

void main() => runApp(const AgenticVoiceApp());

class AgenticVoiceApp extends StatelessWidget {
  const AgenticVoiceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Agentic Voice',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _kNavy,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4a90d9),
        brightness: Brightness.dark,
      ).copyWith(surface: _kNavy),
      appBarTheme: const AppBarTheme(
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      cardTheme: const CardThemeData(color: _kCard),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _kAccent,
          foregroundColor: Colors.white,
        ),
      ),
    ),
    home: const VoiceHomePage(),
  );
}

enum VoiceMode { tools, agent }

class VoiceHomePage extends StatefulWidget {
  const VoiceHomePage({super.key});

  @override
  State<VoiceHomePage> createState() => _VoiceHomePageState();
}

class _VoiceHomePageState extends State<VoiceHomePage> {
  // Setup.
  final _tokenController = TextEditingController();
  bool _busy = false;
  bool _ready = false;
  String _status = 'Download the models to begin.';

  // Pipeline components (owned + closed here; VoiceSession owns none of them).
  SpeechRecognizer? _recognizer;
  SpeechSynthesizer? _synthesizer;
  InferenceModel? _model;

  // Current mode's LLM binding (only one is live at a time).
  VoiceMode _mode = VoiceMode.tools;
  InferenceChat? _toolsChat;
  AgentSession? _agent;

  // Audio I/O (app-owned, per the VoiceSession contract).
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _recording = false;
  bool _turnRunning = false;

  // Transcript / reply for the UI.
  String _transcript = '';
  String _reply = '';
  final List<String> _toolLog = [];

  @override
  void dispose() {
    _tokenController.dispose();
    _recorder.dispose();
    _player.dispose();
    _toolsChat?.session.close();
    _agent?.close();
    _model?.close();
    _recognizer?.close();
    _synthesizer?.close();
    super.dispose();
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  /// Try a device-local staged LLM first (offline, no token); else download the
  /// gated model with the entered token.
  Future<String?> _stagedLlmPath() async {
    final docs = await getApplicationDocumentsDirectory();
    final p = '${docs.path}/$_llmFileName';
    return File(p).existsSync() ? p : null;
  }

  Future<void> _setup() async {
    setState(() {
      _busy = true;
      _status = 'Registering engines…';
    });
    try {
      final token = _tokenController.text.trim();
      await FlutterGemma.initialize(
        huggingFaceToken: token.isEmpty ? null : token,
        sttBackends: const [LiteRtSttBackend()],
        ttsBackends: const [LiteRtTtsBackend()],
        inferenceEngines: const [LiteRtLmEngine()],
      );

      setState(() => _status = 'Installing STT (Moonshine)…');
      await FlutterGemma.installStt()
          .modelFromNetwork(_sttModelUrl, token: token.isEmpty ? null : token)
          .tokenizerFromNetwork(
            _sttTokenizerUrl,
            token: token.isEmpty ? null : token,
          )
          .ofType(SttModelType.moonshine)
          .install();

      setState(() => _status = 'Installing LLM (Gemma 4 E2B)…');
      final staged = await _stagedLlmPath();
      final llm = FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      );
      if (staged != null) {
        await llm.fromFile(staged).install();
      } else {
        if (token.isEmpty) {
          throw StateError(
            'Gemma 4 is gated: enter a HuggingFace token, or stage '
            '$_llmFileName in the app documents directory.',
          );
        }
        await llm.fromNetwork(_llmUrl, token: token).install();
      }

      setState(() => _status = 'Installing TTS (Inflect)…');
      await FlutterGemma.installTts()
          .fromNetwork(_ttsUrl)
          .ofType(TtsModelType.inflect)
          .install();

      _recognizer = await FlutterGemma.getActiveStt();
      _synthesizer = await FlutterGemma.getActiveTts();
      // CPU: the voice path loads Inflect (Metal) alongside the LLM; a concurrent
      // Metal GPU load is flaky on desktop — CPU keeps the demo deterministic.
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.cpu,
      );
      await _bindMode(_mode);

      setState(() {
        _ready = true;
        _status = 'Ready — hold the mic, or tap "Demo turn".';
      });
    } catch (e) {
      setState(() => _status = 'Setup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Mode binding (one LLM binding live at a time) ───────────────────────────

  final _tools = const [
    Tool(
      name: 'get_current_time',
      description: "Get the user's current local date and time.",
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'show_alert',
      description: 'Show an on-screen alert with a title and message.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'The alert title'},
          'message': {'type': 'string', 'description': 'The alert body'},
        },
        'required': ['title', 'message'],
      },
    ),
  ];

  Map<String, dynamic> _onToolCall(FunctionCallResponse call) {
    setState(() => _toolLog.add(call.name));
    switch (call.name) {
      case 'get_current_time':
        return {'now': DateTime.now().toLocal().toString()};
      case 'show_alert':
        final args = call.args;
        final title = '${args['title'] ?? 'Alert'}';
        final message = '${args['message'] ?? ''}';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$title — $message')));
          }
        });
        return {'status': 'shown'};
      default:
        return {'status': 'unknown tool: ${call.name}'};
    }
  }

  Future<void> _bindMode(VoiceMode mode) async {
    await _toolsChat?.session.close();
    _toolsChat = null;
    await _agent?.close();
    _agent = null;

    final model = _model!;
    if (mode == VoiceMode.tools) {
      _toolsChat = await model.createChat(
        tools: _tools,
        supportsFunctionCalls: true,
        modelType: ModelType.gemma4,
        // toolChoice + sampling make Gemma reliably emit calls (a plain chat
        // tends to answer in prose and never call).
        toolChoice: ToolChoice.auto,
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        tokenBuffer: 256,
        // The reply is SPOKEN, then synthesized in one Inflect pass — keep it
        // short or TTS crawls. A one-sentence cap keeps each turn snappy.
        systemInstruction:
            'You are a concise voice assistant. Reply in ONE short, natural '
            'sentence that will be read aloud. No lists, no markdown.',
        // Safe ceiling that fits a function-call JSON; the systemInstruction
        // keeps the actual spoken answer to ~one sentence.
        maxOutputTokens: 128,
      );
    } else {
      // Full agent over the bundled skills (calculate-hash JS, etc.). The skills
      // ship in flutter_gemma_agent's own assets, so no bundling here.
      final source = AssetSkillSource();
      final skills = await source.load();
      final registry = SkillRegistry()..addAll(skills, selected: true);
      _agent = await AgentSession.fromModel(
        model,
        registry: registry,
        executors: [
          TextSkillExecutor(),
          JsSkillExecutor(sourceFor: source.jsSkillSourceFor),
        ],
        // Cap the spoken answer so TTS stays snappy (agent turns can otherwise
        // ramble; this bounds each generation, tool calls included).
        maxOutputTokens: 128,
      );
    }
  }

  Future<void> _switchMode(VoiceMode mode) async {
    if (mode == _mode || _busy || _turnRunning) return;
    setState(() {
      _busy = true;
      _mode = mode;
      _status = 'Switching to ${mode.name} mode…';
    });
    try {
      await _bindMode(mode);
      setState(() => _status = 'Ready — ${mode.name} mode.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  VoiceSession _buildSession() {
    final recognizer = _recognizer!;
    final synthesizer = _synthesizer!;
    if (_mode == VoiceMode.tools) {
      return VoiceSession.fromChat(
        recognizer: recognizer,
        chat: _toolsChat!,
        synthesizer: synthesizer,
        onToolCall: _onToolCall,
      );
    }
    return VoiceSession.custom(
      recognizer: recognizer,
      responder: agentVoiceResponder(_agent!),
      synthesizer: synthesizer,
    );
  }

  // ── Turns ───────────────────────────────────────────────────────────────────

  Future<void> _runTurn(Uint8List pcm16kMono) async {
    if (_turnRunning) return;
    setState(() {
      _turnRunning = true;
      _transcript = '';
      _reply = '';
      _toolLog.clear();
      _status = 'Thinking…';
    });
    final session = _buildSession();
    try {
      await for (final event in session.runTurn(pcm16kMono)) {
        switch (event) {
          case VoiceTranscriptEvent(:final text):
            setState(() => _transcript = text);
          case VoiceReplyTextEvent(:final chunk):
            setState(() => _reply += chunk);
          case VoiceReplyAudioEvent(:final pcm, :final sampleRate):
            await _playReply(pcm, sampleRate);
          case VoiceErrorEvent(:final error):
            setState(() => _status = 'Turn error: $error');
          case VoiceTurnCompleteEvent():
            setState(() => _status = 'Done.');
          default:
            break;
        }
      }
    } catch (e) {
      setState(() => _status = 'Turn failed: $e');
    } finally {
      if (mounted) setState(() => _turnRunning = false);
    }
  }

  Future<void> _playReply(Uint8List pcm, int sampleRate) async {
    final wav = AudioConverter.pcmToWav(pcm, sampleRate: sampleRate);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/reply.wav');
    await file.writeAsBytes(wav, flush: true);
    await _player.setFilePath(file.path);
    await _player.play();
  }

  Future<void> _holdToTalk() async {
    if (_turnRunning) return;
    if (!await _recorder.hasPermission()) {
      setState(() => _status = 'Microphone permission denied.');
      return;
    }
    final dir = await getTemporaryDirectory();
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: kIsWeb ? '' : '${dir.path}/capture.wav',
    );
    setState(() {
      _recording = true;
      _status = 'Listening… release to send.';
    });
  }

  Future<void> _releaseToSend() async {
    if (!_recording) return;
    final path = await _recorder.stop();
    setState(() => _recording = false);
    if (path == null) {
      setState(() => _status = 'No audio captured.');
      return;
    }
    final wavBytes = await File(path).readAsBytes();
    final parsed = AudioConverter.parseWav(wavBytes);
    final pcm = AudioConverter.toPCM16kHzMono(
      parsed.pcmData,
      sourceSampleRate: parsed.sampleRate,
      sourceChannels: parsed.channels,
    );
    await _runTurn(pcm);
  }

  Future<void> _demoTurn() async {
    final data = await rootBundle.load('assets/test_audio.wav');
    final parsed = AudioConverter.parseWav(data.buffer.asUint8List());
    final pcm = AudioConverter.toPCM16kHzMono(
      parsed.pcmData,
      sourceSampleRate: parsed.sampleRate,
      sourceChannels: parsed.channels,
    );
    await _runTurn(pcm);
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agentic Voice')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _ready ? _buildLoop() : _buildSetup(),
      ),
    );
  }

  Widget _buildSetup() {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset('assets/gemma.png', height: 150),
              ),
              const SizedBox(height: 20),
              const Text(
                'On-device agentic voice',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'STT (Moonshine) → LLM (Gemma 4 E2B, tools + agent) → '
                'TTS (Inflect), all on device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'HuggingFace token (for the gated Gemma download)',
                  helperText:
                      'Optional if the .litertlm is already staged in app documents.',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _setup,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: const Text('Download & initialize'),
              ),
              const SizedBox(height: 16),
              Text(_status, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<VoiceMode>(
          segments: const [
            ButtonSegment(
              value: VoiceMode.tools,
              label: Text('Tools'),
              icon: Icon(Icons.build),
            ),
            ButtonSegment(
              value: VoiceMode.agent,
              label: Text('Agent'),
              icon: Icon(Icons.smart_toy),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => _switchMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _mode == VoiceMode.tools
              ? 'Try: "What time is it?" or "Show an alert saying hello".'
              : 'Try: "Calculate the hash of hello".',
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _card('You said', _transcript),
                _card('Reply', _reply),
                if (_toolLog.isNotEmpty)
                  _card('Tools called', _toolLog.join(', ')),
              ],
            ),
          ),
        ),
        Text(_status, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTapDown: (_) => _holdToTalk(),
                onTapUp: (_) => _releaseToSend(),
                onTapCancel: _releaseToSend,
                child: FilledButton.icon(
                  onPressed: _turnRunning ? null : () {},
                  style: FilledButton.styleFrom(
                    backgroundColor: _recording ? Colors.red : null,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  icon: const Icon(Icons.mic),
                  label: Text(_recording ? 'Release to send' : 'Hold to talk'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _turnRunning ? null : _demoTurn,
              icon: const Icon(Icons.play_circle),
              label: const Text('Demo turn'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _card(String title, String body) {
    if (body.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(body),
          ],
        ),
      ),
    );
  }
}
