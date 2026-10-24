/// Genkit Dart plugin for flutter_edge_ai — local on-device AI inference.
///
/// Wraps [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) as a Genkit
/// model provider, enabling on-device inference with any model a registered
/// flutter_edge_ai engine runs.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:flutter_edge_ai/flutter_edge_ai.dart';
/// import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
/// import 'package:genkit/genkit.dart';
/// import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
///
/// // 1. Register an engine and install a model (host app responsibility).
/// await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);
/// await FlutterEdgeAi.installModel(
///   modelType: ModelType.gemma4,
///   fileType: ModelFileType.litertlm,
/// ).fromNetwork(
///   'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
/// ).install();
///
/// // 2. Create Genkit with the plugin.
/// final ai = Genkit(plugins: [
///   GenkitFlutterEdgeAiPlugin(
///     models: [
///       FlutterEdgeAiModelConfig(
///         name: 'gemma-4-e2b',
///         modelType: ModelType.gemma4,
///       ),
///     ],
///   ),
/// ]);
///
/// // 3. Generate.
/// final response = await ai.generate(
///   model: flutterEdgeAi.model('gemma-4-e2b'),
///   prompt: 'Tell me a joke',
/// );
/// print(response.text);
/// ```
library;

import 'package:genkit/genkit.dart';

import 'src/flutter_edge_ai_options.dart';
import 'src/flutter_edge_ai_plugin.dart';
import 'src/flutter_edge_ai_runtime.dart';
import 'src/model_options_parse.dart';
import 'src/model_slot.dart';

export 'src/decider_route_classifier.dart'
    show DeciderRouteClassifier, deciderRouteClassifier;
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
        customOptions: FlutterEdgeAiModelOptions.$schema,
      );

  /// Loads the active on-device model with [model]'s config ahead of the
  /// first request, which then reuses it: a genkit_hybrid target's warm-up,
  /// `HybridTarget.onDevice(ref, warmUp: flutterEdgeAi.warmUp)`. An invalid
  /// config is INVALID_ARGUMENT and a failed load fails as a request's would.
  /// [runtime] is for tests.
  Future<void> warmUp(
    ModelRef model, {
    FlutterEdgeAiRuntime runtime = const DefaultFlutterEdgeAiRuntime(),
  }) async {
    final config = model.config;
    final Map<String, dynamic>? json = switch (config) {
      null => null,
      final Map map => map.cast<String, dynamic>(),
      final FlutterEdgeAiModelOptions options => options.toJson(),
      _ => throw GenkitException(
        'Model "${model.name}": its config is neither a Map nor '
        'FlutterEdgeAiModelOptions.',
        status: StatusCode.invalidArgument,
      ),
    };
    final options = await parseModelOptions(json);
    await FlutterEdgeAiModelSlot(runtime).load(loadParamsOf(options));
  }

  /// Returns an [EmbedderRef] for the given embedder name registered by this plugin.
  EmbedderRef<FlutterEdgeAiEmbedConfig> embedder(String name) =>
      embedderRef<FlutterEdgeAiEmbedConfig>(
        '${GenkitFlutterEdgeAiPlugin.prefix}/$name',
        customOptions: FlutterEdgeAiEmbedConfig.$schema,
      );
}

/// Global convenience instance for referencing flutter-edge-ai models and embedders.
const flutterEdgeAi = FlutterEdgeAiPluginHandle();
