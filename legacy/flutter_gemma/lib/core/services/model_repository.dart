import 'package:flutter_gemma/core/domain/model_source.dart';

/// Abstraction for model metadata persistence
/// Stores information about installed models (NOT the model files themselves)
///
/// Platform implementations:
/// - SharedPreferencesModelRepository: uses SharedPreferences
/// - SQLiteModelRepository: uses SQLite database
/// - InMemoryModelRepository: for testing
abstract interface class ModelRepository {
  /// Saves model metadata after successful installation
  ///
  /// Stores:
  /// - Model source (where it came from)
  /// - Installation timestamp
  /// - File paths
  /// - Model type (inference/embedding)
  Future<void> saveModel(ModelInfo info);

  /// Loads model metadata by ID
  ///
  /// Returns null if model not found
  Future<ModelInfo?> loadModel(String id);

  /// Deletes model metadata
  ///
  /// Note: This only deletes metadata, not the actual model files
  /// Use FileSystemService to delete actual files
  Future<void> deleteModel(String id);

  /// Lists all installed models
  Future<List<ModelInfo>> listInstalled();

  /// Checks if a model is installed by ID
  Future<bool> isInstalled(String id);
}

/// Model metadata stored in repository
class ModelInfo {
  final String id;
  final ModelSource source;
  final DateTime installedAt;
  final int sizeBytes;
  final ModelType type;
  final bool hasLoraWeights;

  const ModelInfo({
    required this.id,
    required this.source,
    required this.installedAt,
    required this.sizeBytes,
    required this.type,
    required this.hasLoraWeights,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': _sourceToJson(source),
    'installedAt': installedAt.toIso8601String(),
    'sizeBytes': sizeBytes,
    'type': type.toString(),
    'hasLoraWeights': hasLoraWeights,
  };

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    id: json['id'] as String,
    source: _sourceFromJson(json['source'] as Map<String, dynamic>),
    installedAt: DateTime.parse(json['installedAt'] as String),
    sizeBytes: json['sizeBytes'] as int,
    type: ModelType.values.firstWhere((e) => e.toString() == json['type']),
    hasLoraWeights: json['hasLoraWeights'] as bool,
  );

  static Map<String, dynamic> _sourceToJson(ModelSource source) =>
      switch (source) {
        NetworkSource(:final url) => {'type': 'network', 'url': url},
        AssetSource(:final path) => {'type': 'asset', 'path': path},
        BundledSource(:final resourceName) => {
          'type': 'bundled',
          'resourceName': resourceName,
        },
        FileSource(:final path) => {'type': 'file', 'path': path},
      };

  static ModelSource _sourceFromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'network' => ModelSource.network(json['url'] as String),
      'asset' => ModelSource.asset(json['path'] as String),
      'bundled' => ModelSource.bundled(json['resourceName'] as String),
      'file' => ModelSource.file(json['path'] as String),
      _ => throw ArgumentError('Unknown source type: $type'),
    };
  }
}

/// Type of model
enum ModelType { inference, embedding, stt, tts }
