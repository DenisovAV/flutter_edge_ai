/// Genkit Dart plugin for flutter_edge_ai — local on-device AI inference.
///
/// Wraps [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) as a Genkit
/// model provider, enabling on-device inference with Google Gemma, DeepSeek,
/// Qwen, Llama, and other supported architectures.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:genkit/genkit.dart';
/// import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
/// import 'package:flutter_edge_ai/flutter_edge_ai.dart';
///
/// // 1. Initialize flutter_edge_ai and install a model (host app responsibility).
/// await FlutterEdgeAi.initialize();
/// await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
///   .fromNetwork('https://...')
///   .install();
///
/// // 2. Create Genkit with the plugin.
/// final ai = Genkit(plugins: [
///   GenkitFlutterEdgeAiPlugin(
///     models: [
///       FlutterEdgeAiModelConfig(
///         name: 'gemma-3-nano',
///         modelType: ModelType.gemmaIt,
///       ),
///     ],
///     embedders: [
///       FlutterEdgeAiEmbedderConfig(name: 'embedding-gemma-300m'),
///     ],
///   ),
/// ]);
///
/// // 3. Generate.
/// final response = await ai.generate(
///   model: flutterEdgeAi.model('gemma-3-nano'),
///   prompt: 'Tell me a joke',
/// );
/// print(response.text);
/// ```
library;

import 'package:genkit/genkit.dart';

import 'src/flutter_edge_ai_options.dart';
import 'src/flutter_edge_ai_plugin.dart';

export 'src/flutter_edge_ai_options.dart'
    show FlutterEdgeAiModelOptions, FlutterEdgeAiEmbedConfig;
export 'src/flutter_edge_ai_plugin.dart'
    show
        GenkitFlutterEdgeAiPlugin,
        FlutterEdgeAiModelConfig,
        FlutterEdgeAiEmbedderConfig;
export 'src/flutter_edge_ai_runtime.dart'
    show FlutterEdgeAiRuntime, DefaultFlutterEdgeAiRuntime;
export 'src/middleware/context_window.dart'
    show
        ContextWindowMiddleware,
        contextWindowMiddlewareDef,
        kContextWindowMiddlewareName,
        trimContext;

/// Convenience handle for referencing flutter-edge-ai models and embedders.
///
/// Usage:
/// ```dart
/// final response = await ai.generate(
///   model: flutterEdgeAi.model('gemma-3-nano'),
///   prompt: 'Hello!',
/// );
/// ```
class FlutterEdgeAiPluginHandle {
  const FlutterEdgeAiPluginHandle();

  /// Returns a [ModelRef] for the given model name registered by this plugin.
  ModelRef<FlutterEdgeAiModelOptions> model(String name) =>
      modelRef<FlutterEdgeAiModelOptions>(
        '${GenkitFlutterEdgeAiPlugin.prefix}/$name',
      );

  /// Returns an [EmbedderRef] for the given embedder name registered by this plugin.
  EmbedderRef<FlutterEdgeAiEmbedConfig> embedder(String name) =>
      embedderRef<FlutterEdgeAiEmbedConfig>(
        '${GenkitFlutterEdgeAiPlugin.prefix}/$name',
      );
}

/// Global convenience instance for referencing flutter-edge-ai models and embedders.
const flutterEdgeAi = FlutterEdgeAiPluginHandle();
