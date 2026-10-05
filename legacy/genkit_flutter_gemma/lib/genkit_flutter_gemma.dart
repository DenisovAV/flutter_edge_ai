/// Genkit Dart plugin for flutter_gemma — local on-device AI inference.
///
/// Wraps [flutter_gemma](https://pub.dev/packages/flutter_gemma) as a Genkit
/// model provider, enabling on-device inference with Google Gemma, DeepSeek,
/// Qwen, Llama, and other supported architectures.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:genkit/genkit.dart';
/// import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';
/// import 'package:flutter_gemma/flutter_gemma.dart';
///
/// // 1. Initialize flutter_gemma and install a model (host app responsibility).
/// await FlutterGemma.initialize();
/// await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
///   .fromNetwork('https://...')
///   .install();
///
/// // 2. Create Genkit with the plugin.
/// final ai = Genkit(plugins: [
///   GenkitFlutterGemmaPlugin(
///     models: [
///       FlutterGemmaModelConfig(
///         name: 'gemma-3-nano',
///         modelType: ModelType.gemmaIt,
///       ),
///     ],
///     embedders: [
///       FlutterGemmaEmbedderConfig(name: 'embedding-gemma-300m'),
///     ],
///   ),
/// ]);
///
/// // 3. Generate.
/// final response = await ai.generate(
///   model: flutterGemma.model('gemma-3-nano'),
///   prompt: 'Tell me a joke',
/// );
/// print(response.text);
/// ```
library;

import 'package:genkit/genkit.dart';

import 'src/flutter_gemma_options.dart';
import 'src/flutter_gemma_plugin.dart';

export 'src/flutter_gemma_options.dart'
    show FlutterGemmaModelOptions, FlutterGemmaEmbedConfig;
export 'src/flutter_gemma_plugin.dart'
    show
        GenkitFlutterGemmaPlugin,
        FlutterGemmaModelConfig,
        FlutterGemmaEmbedderConfig;
export 'src/flutter_gemma_runtime.dart'
    show FlutterGemmaRuntime, DefaultFlutterGemmaRuntime;
export 'src/middleware/context_window.dart'
    show
        ContextWindowMiddleware,
        contextWindowMiddlewareDef,
        kContextWindowMiddlewareName,
        trimContext;

/// Convenience handle for referencing flutter-gemma models and embedders.
///
/// Usage:
/// ```dart
/// final response = await ai.generate(
///   model: flutterGemma.model('gemma-3-nano'),
///   prompt: 'Hello!',
/// );
/// ```
class FlutterGemmaPluginHandle {
  const FlutterGemmaPluginHandle();

  /// Returns a [ModelRef] for the given model name registered by this plugin.
  ModelRef<FlutterGemmaModelOptions> model(String name) =>
      modelRef<FlutterGemmaModelOptions>(
        '${GenkitFlutterGemmaPlugin.prefix}/$name',
      );

  /// Returns an [EmbedderRef] for the given embedder name registered by this plugin.
  EmbedderRef<FlutterGemmaEmbedConfig> embedder(String name) =>
      embedderRef<FlutterGemmaEmbedConfig>(
        '${GenkitFlutterGemmaPlugin.prefix}/$name',
      );
}

/// Global convenience instance for referencing flutter-gemma models and embedders.
const flutterGemma = FlutterGemmaPluginHandle();
