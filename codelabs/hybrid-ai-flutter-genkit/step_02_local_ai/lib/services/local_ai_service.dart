import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

import 'ai_service.dart';

// The on-device LLM installs straight from Hugging Face by repo + file. The
// browser engine only runs dedicated web builds — Gemma 3 1B has none — so on
// web this installs Gemma 4 E2B's public web build instead (~2.0 GB, vs
// ~0.6 GB for the gated native file).
const String _hfRepo = kIsWeb
    ? 'litert-community/gemma-4-E2B-it-litert-lm'
    : 'litert-community/Gemma3-1B-IT';
const String _hfModelFile = kIsWeb
    ? 'gemma-4-E2B-it-web.litertlm'
    : 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const ModelType _modelType = kIsWeb ? ModelType.gemma4 : ModelType.gemmaIt;

// Pass at build time: flutter run --dart-define=HF_TOKEN=hf_xxx
const String _hfToken = String.fromEnvironment('HF_TOKEN');

const String _modelName = 'gemma-3-1b-it';
const String _embedderName = 'embedding-gemma-300m';

class LocalAIService implements AIService {
  Genkit? _ai;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  // Shared Genkit instance exposed for RagService to use for embeddings.
  Genkit get ai {
    final ai = _ai;
    if (ai == null) throw StateError('LocalAIService not initialized');
    return ai;
  }

  String get embedderName => _embedderName;

  @override
  Future<void> initialize({void Function(int)? onProgress}) async {
    if (_isInitialized) return;

    // flutter_edge_ai 1.x registers no engine by default — opt into LiteRT-LM.
    // `webStorageMode: streaming` (OPFS-backed) is what the size demands: the
    // 2.0 GB web build sits right on the ~2 GB blob ceiling the default
    // cacheApi mode would have to buffer it into, so the @litert-lm/core
    // engine reads it from OPFS as a ReadableStream. Ignored on non-web.
    await FlutterEdgeAi.initialize(
      webStorageMode: WebStorageMode.streaming,
      inferenceEngines: [LiteRtLmEngine()],
    );

    // Download the .litertlm model (skipped if already installed).
    await FlutterEdgeAi.installModel(
          modelType: _modelType,
          fileType: ModelFileType.litertlm,
        )
        .fromHuggingFace(
          _hfRepo,
          file: _hfModelFile,
          token: _hfToken.isEmpty ? null : _hfToken,
        )
        .withProgress((p) => onProgress?.call(p)) // p is int 0..100
        .install();

    // No installEmbedder() call here: this app never computes an embedding
    // (RagService doesn't exist until Step 6, by which point this whole
    // file is retired — see Step 4) and initialize() registers no embedding
    // backend either, so downloading the ~300 MB model here would just be
    // wasted bandwidth. embedderName/embedders below stay purely
    // declarative, ready for Step 4's AiEngine to actually install it.

    // One Genkit instance for both inference and embeddings.
    _ai = Genkit(
      plugins: [
        GenkitFlutterEdgeAiPlugin(
          models: [
            FlutterEdgeAiModelConfig(
              name: _modelName,
              modelType: _modelType,
              fileType: ModelFileType.litertlm,
            ),
          ],
          embedders: [FlutterEdgeAiEmbedderConfig(name: _embedderName)],
        ),
      ],
    );

    _isInitialized = true;
  }

  @override
  Stream<String> generateResponseStream(String prompt) async* {
    final stream = ai.generateStream(
      model: flutterEdgeAi.model(_modelName),
      prompt: prompt,
    );

    await for (final chunk in stream) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  @override
  Future<void> dispose() async {
    _ai = null;
    _isInitialized = false;
  }
}
