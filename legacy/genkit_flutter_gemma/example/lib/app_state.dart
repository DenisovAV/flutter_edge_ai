import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide Message;
import 'package:flutter_gemma/flutter_gemma.dart' as gemma show ModelType;
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

class ChatMessage {
  final String text;
  final bool isUser;

  const ChatMessage({required this.text, required this.isUser});
}

class EmbeddingResult {
  final String label;
  final double similarity;

  const EmbeddingResult({required this.label, required this.similarity});
}

class AppState extends ChangeNotifier {
  Genkit? _ai;
  Genkit? get ai => _ai;

  // Model status
  bool inferenceInstalled = false;
  bool embedderInstalled = false;
  bool isDownloadingInference = false;
  bool isDownloadingEmbedder = false;
  int inferenceProgress = 0;
  int embedderProgress = 0;
  String? error;

  // HuggingFace token
  String hfToken = const String.fromEnvironment('HF_TOKEN');

  // Model config
  String inferenceUrl = _isDesktop
      ? 'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm'
      : 'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.task';

  String embedderModelUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite';
  String embedderTokenizerUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model';

  int _maxTokens = 1024;
  int get maxTokens => _maxTokens;
  set maxTokens(int value) {
    _maxTokens = value;
    notifyListeners();
  }

  // Chat state
  List<ChatMessage> chatMessages = [];
  bool isGenerating = false;
  bool _useStreaming = true;
  bool get useStreaming => _useStreaming;
  set useStreaming(bool value) {
    _useStreaming = value;
    notifyListeners();
  }

  String currentStreamText = '';

  // Embeddings
  List<EmbeddingResult> embeddingResults = [];

  // Tools
  String? lastToolResult;
  bool isToolGenerating = false;
  bool _agentMode = false;
  bool get agentMode => _agentMode;
  set agentMode(bool value) {
    _agentMode = value;
    notifyListeners();
  }

  static const _modelName = 'gemma-3-1b-it';
  static const _embedderName = 'embedding-gemma-300m';

  void _logError(String context, Object e, [StackTrace? stack]) {
    debugPrint('[$context] $e');
    if (stack != null) debugPrint('$stack');
    developer.log('$e', name: context, error: e, stackTrace: stack);
  }

  ModelRef<FlutterGemmaModelOptions> get modelRef =>
      flutterGemma.model(_modelName);
  EmbedderRef<FlutterGemmaEmbedConfig> get embedderRef =>
      flutterGemma.embedder(_embedderName);

  Future<void> initialize() async {
    try {
      inferenceInstalled = FlutterGemma.hasActiveModel();
      embedderInstalled = FlutterGemma.hasActiveEmbedder();
      if (inferenceInstalled || embedderInstalled) {
        _createGenkit();
      }
    } catch (e, stack) {
      _logError('AppState.initialize', e, stack);
      error = 'Init failed: $e';
    }
    notifyListeners();
  }

  void _createGenkit() {
    final models = <FlutterGemmaModelConfig>[];
    final embedders = <FlutterGemmaEmbedderConfig>[];

    if (inferenceInstalled) {
      models.add(
        FlutterGemmaModelConfig(
          name: _modelName,
          modelType: gemma.ModelType.gemmaIt,
          // Desktop downloads the .litertlm model (see inferenceUrl above) and so
          // MUST declare ModelFileType.litertlm — otherwise the engine registry
          // routes the .litertlm file to the MediaPipe (.task) engine, which
          // can't load it. Mobile/web download the .task model → MediaPipe.
          fileType: _isDesktop ? ModelFileType.litertlm : ModelFileType.task,
        ),
      );
    }
    if (embedderInstalled) {
      embedders.add(FlutterGemmaEmbedderConfig(name: _embedderName));
    }

    if (models.isEmpty && embedders.isEmpty) return;

    _ai = Genkit(
      plugins: [GenkitFlutterGemmaPlugin(models: models, embedders: embedders)],
    );
  }

  void reinitializeGenkit() {
    _ai = null;
    _createGenkit();
    notifyListeners();
  }

  Future<void> downloadInferenceModel() async {
    if (isDownloadingInference) return;
    isDownloadingInference = true;
    inferenceProgress = 0;
    error = null;
    notifyListeners();

    try {
      await FlutterGemma.installModel(modelType: gemma.ModelType.gemmaIt)
          .fromNetwork(inferenceUrl, token: hfToken.isNotEmpty ? hfToken : null)
          .withProgress((progress) {
            inferenceProgress = progress;
            notifyListeners();
          })
          .install();

      inferenceInstalled = true;
      _createGenkit();
    } catch (e, stack) {
      _logError('AppState.downloadInferenceModel', e, stack);
      error = 'Download failed: $e';
    } finally {
      isDownloadingInference = false;
      notifyListeners();
    }
  }

  Future<void> downloadEmbedderModel() async {
    if (isDownloadingEmbedder) return;
    isDownloadingEmbedder = true;
    embedderProgress = 0;
    error = null;
    notifyListeners();

    try {
      final installer = FlutterGemma.installEmbedder().modelFromNetwork(
        embedderModelUrl,
        token: hfToken.isNotEmpty ? hfToken : null,
      );

      // flutter_gemma 0.15.2+ unified embedding on a single LiteRT C API path,
      // so the per-platform iOS tokenizer (iosPath) was dropped — the same
      // tokenizer source now works on every platform.
      final withTokenizer = installer.tokenizerFromNetwork(
        embedderTokenizerUrl,
        token: hfToken.isNotEmpty ? hfToken : null,
      );

      await withTokenizer.install();

      embedderInstalled = true;
      _createGenkit();
    } catch (e, stack) {
      _logError('AppState.downloadEmbedderModel', e, stack);
      error = 'Embedder download failed: $e';
    } finally {
      isDownloadingEmbedder = false;
      notifyListeners();
    }
  }

  Future<void> sendMessage(String text) async {
    if (_ai == null || !inferenceInstalled || isGenerating) return;

    chatMessages.add(ChatMessage(text: text, isUser: true));
    isGenerating = true;
    currentStreamText = '';
    notifyListeners();

    try {
      final messages = chatMessages.map((m) {
        return Message(
          role: m.isUser ? Role.user : Role.model,
          content: [TextPart(text: m.text)],
        );
      }).toList();

      if (useStreaming) {
        final stream = _ai!.generateStream(
          model: modelRef,
          messages: messages,
          config: FlutterGemmaModelOptions(maxTokens: maxTokens),
        );

        await for (final chunk in stream) {
          final token = chunk.text;
          if (token.isNotEmpty) {
            currentStreamText += token;
            notifyListeners();
          }
        }

        chatMessages.add(ChatMessage(text: currentStreamText, isUser: false));
      } else {
        final response = await _ai!.generate(
          model: modelRef,
          messages: messages,
          config: FlutterGemmaModelOptions(maxTokens: maxTokens),
        );

        chatMessages.add(ChatMessage(text: response.text, isUser: false));
      }
    } catch (e, stack) {
      _logError('AppState.sendMessage', e, stack);
      chatMessages.add(ChatMessage(text: 'Error: $e', isUser: false));
    } finally {
      isGenerating = false;
      currentStreamText = '';
      notifyListeners();
    }
  }

  void clearChat() {
    chatMessages.clear();
    notifyListeners();
  }

  Future<void> computeSimilarity(List<String> texts) async {
    if (_ai == null || !embedderInstalled) return;
    if (texts.length < 2) return;

    embeddingResults = [];
    notifyListeners();

    try {
      final embeddings = await _ai!.embed(
        embedder: embedderRef,
        documents: texts
            .map((t) => DocumentData(content: [TextPart(text: t)]))
            .toList(),
      );

      final queryEmb = embeddings[0].embedding;
      final results = <EmbeddingResult>[];
      for (int i = 1; i < embeddings.length; i++) {
        final sim = _cosineSimilarity(queryEmb, embeddings[i].embedding);
        results.add(EmbeddingResult(label: texts[i], similarity: sim));
      }
      embeddingResults = results;
    } catch (e, stack) {
      _logError('AppState.computeSimilarity', e, stack);
      error = 'Embedding failed: $e';
    }
    notifyListeners();
  }

  Future<void> generateWithTools(String prompt) async {
    if (_ai == null || !inferenceInstalled || isToolGenerating) return;

    isToolGenerating = true;
    lastToolResult = null;
    error = null;
    notifyListeners();

    try {
      final getWeather = _ai!.defineTool<Map<String, dynamic>, String>(
        name: 'get_weather',
        description: 'Get current weather for a city',
        fn: (input, _) async {
          final city = input['city'] ?? 'unknown';
          return ToolResult.response('Weather in $city: 18°C, partly cloudy');
        },
      );

      final calculate = _ai!.defineTool<Map<String, dynamic>, String>(
        name: 'calculate',
        description: 'Calculate a mathematical expression',
        fn: (input, _) async {
          final expr = input['expression'] ?? '';
          return ToolResult.response('Result of $expr = 42');
        },
      );

      final response = await _ai!.generate(
        model: modelRef,
        prompt: prompt,
        tools: [getWeather, calculate],
        config: FlutterGemmaModelOptions(maxTokens: maxTokens),
        returnToolRequests: !_agentMode,
        maxTurns: _agentMode ? 5 : null,
      );

      final parts = response.message?.content ?? [];
      final buffer = StringBuffer();
      for (final part in parts) {
        if (part.isReasoning) {
          buffer.writeln('[Reasoning] ${part.reasoning}');
        } else if (part.isText) {
          buffer.writeln(part.text);
        } else if (part.isToolRequest) {
          buffer.writeln(
            'Tool call: ${part.toolRequest!.name}(${part.toolRequest!.input})',
          );
        }
      }
      lastToolResult = buffer.toString().trim();
    } catch (e, stack) {
      _logError('AppState.generateWithTools', e, stack);
      lastToolResult = 'Error: $e';
    } finally {
      isToolGenerating = false;
      notifyListeners();
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length);
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}
