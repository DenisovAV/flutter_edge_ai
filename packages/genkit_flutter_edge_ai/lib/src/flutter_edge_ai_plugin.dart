import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'flutter_edge_ai_embedder.dart';
import 'flutter_edge_ai_model.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';
import 'middleware/context_window.dart';

/// Configuration for a single model exposed by [GenkitFlutterEdgeAiPlugin].
class FlutterEdgeAiModelConfig {
  FlutterEdgeAiModelConfig({
    required this.name,
    required this.modelType,
    this.fileType = gemma.ModelFileType.task,
  }) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Model name must not be empty');
    }
  }

  /// Display name for this model (e.g. 'gemma-3-nano').
  /// Registered as `flutter-edge-ai/<name>` in Genkit.
  final String name;

  /// The flutter_edge_ai model architecture type.
  final gemma.ModelType modelType;

  /// The model file format (.task, .binary, or .litertlm).
  final gemma.ModelFileType fileType;
}

/// Configuration for an embedder exposed by [GenkitFlutterEdgeAiPlugin].
class FlutterEdgeAiEmbedderConfig {
  FlutterEdgeAiEmbedderConfig({required this.name}) {
    if (name.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Embedder name must not be empty',
      );
    }
  }

  /// Display name for this embedder (e.g. 'embedding-gemma-300m').
  /// Registered as `flutter-edge-ai/<name>` in Genkit.
  final String name;
}

/// Genkit plugin that bridges flutter_edge_ai for on-device AI inference
/// and embedding generation.
///
/// Usage:
/// ```dart
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
/// final response = await ai.generate(
///   model: flutterEdgeAi.model('gemma-3-nano'),
///   prompt: 'Hello!',
/// );
/// ```
///
/// **Important**: The host app is responsible for installing models via
/// `FlutterEdgeAi.installModel()` / `FlutterEdgeAi.installEmbedder()`.
class GenkitFlutterEdgeAiPlugin extends GenkitPlugin {
  GenkitFlutterEdgeAiPlugin({
    required List<FlutterEdgeAiModelConfig> models,
    List<FlutterEdgeAiEmbedderConfig> embedders = const [],
    FlutterEdgeAiRuntime? runtime,
  }) : models = List.unmodifiable(models),
       embedders = List.unmodifiable(embedders),
       runtime = runtime ?? const DefaultFlutterEdgeAiRuntime() {
    // Validate name uniqueness.
    final modelNames = models.map((c) => c.name).toSet();
    if (modelNames.length != models.length) {
      throw ArgumentError('Duplicate model names in configuration');
    }
    final embedderNames = embedders.map((c) => c.name).toSet();
    if (embedderNames.length != embedders.length) {
      throw ArgumentError('Duplicate embedder names in configuration');
    }
  }

  static const prefix = 'flutter-edge-ai';

  /// List of model configurations this plugin exposes.
  final List<FlutterEdgeAiModelConfig> models;

  /// List of embedder configurations this plugin exposes.
  final List<FlutterEdgeAiEmbedderConfig> embedders;

  /// Runtime used to obtain inference and embedding models.
  final FlutterEdgeAiRuntime runtime;

  /// Cache for resolved actions to avoid recreating on every resolve() call.
  final Map<String, Action> _resolvedActions = {};

  @override
  String get name => prefix;

  /// Ships the context-window trimmer so apps can guard the on-device KV budget
  /// with `ai.generate(use: [trimContext(...)])`. See [ContextWindowMiddleware].
  @override
  List<GenerateMiddlewareDef> middleware() => [contextWindowMiddlewareDef()];

  @override
  Future<List<ActionMetadata>> list() async {
    final metadata = <ActionMetadata>[];

    for (final config in models) {
      metadata.add(
        ActionMetadata(
          actionType: ActionType.model,
          name: '$prefix/${config.name}',
          metadata: {
            'model': {
              'label': config.name,
              'customOptions': FlutterEdgeAiModelOptions.$schema.jsonSchema(),
              // Shared with the resolved Model's metadata so list() and the live
              // action never diverge (see kFlutterEdgeAiModelSupports).
              'supports': kFlutterEdgeAiModelSupports,
            },
          },
        ),
      );
    }

    for (final config in embedders) {
      metadata.add(
        ActionMetadata(
          actionType: ActionType.embedder,
          name: '$prefix/${config.name}',
          metadata: {
            'embedder': {
              'label': config.name,
              'customOptions': FlutterEdgeAiEmbedConfig.$schema.jsonSchema(),
            },
          },
        ),
      );
    }

    return metadata;
  }

  @override
  Action? resolve(ActionType actionType, String name) {
    final cacheKey = '${actionType.value}:$name';
    final cached = _resolvedActions[cacheKey];
    if (cached != null) return cached;

    if (actionType == ActionType.model) {
      // Registry strips prefix before calling resolve(), so `name` is just
      // the model name (e.g. 'function-gemma-270m-it'), not the full
      // 'flutter-edge-ai/function-gemma-270m-it'.
      final config = models.where((c) => c.name == name).firstOrNull;
      if (config == null) return null;

      final fullName = '$prefix/$name';
      final action = createFlutterEdgeAiModel(
        name: fullName,
        modelType: config.modelType,
        fileType: config.fileType,
        runtime: runtime,
      );
      _resolvedActions[cacheKey] = action;
      return action;
    }

    if (actionType == ActionType.embedder) {
      final config = embedders.where((c) => c.name == name).firstOrNull;
      if (config == null) return null;

      final fullName = '$prefix/$name';
      final action = createFlutterEdgeAiEmbedder(
        name: fullName,
        runtime: runtime,
      );
      _resolvedActions[cacheKey] = action;
      return action;
    }

    return null;
  }

  /// Clears the resolved action cache, allowing actions to be recreated
  /// on the next [resolve] call.
  void dispose() {
    _resolvedActions.clear();
  }
}
