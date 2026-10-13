// A fake embedding backend for deciders on embedders core builds: the shells'
// createEmbeddingModel, the EmbedderCache and the worker isolate are all real;
// only the pass is a table. Text maps to a fixed vector; the pass serves text
// and PNG images (an image embeds as its first byte's direction).

import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';

/// What the pass embeds. Top-level and const, so the worker isolate reads the
/// same table.
const tableVectors = <String, List<double>>{
  'a1': [1, 0, 0],
  'a2': [0.9, 0.1, 0],
  'b1': [0, 1, 0],
  'b2': [0.1, 0.9, 0],
  'about a': [1, 0.05, 0],
  'about b': [0.05, 1, 0],
};

/// Describes a table pass for every spec, reporting [activeBackend].
final class TableBackend extends EmbeddingBackendProvider {
  TableBackend({this.activeBackend = PreferredBackend.cpu});

  final PreferredBackend? activeBackend;

  @override
  String get name => 'table';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async => EmbeddingPassDescriptor<String>(
    engineTag: 'Table',
    factory: _buildTablePass,
    config: config.modelPath,
    activeBackend: activeBackend,
  );
}

EmbeddingPass _buildTablePass(String modelPath) => _TablePass();

/// Runs in core's worker isolate.
final class _TablePass extends EmbeddingPass {
  @override
  Future<EmbeddingPassInfo> load() async => EmbeddingPassInfo(
    dimension: 3,
    modalities: const {EmbeddingModality.text, EmbeddingModality.image},
    imageFormats: {EncodedMediaFormat.png},
  );

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final text = input.text;
    if (text != null) {
      return tableVectors[text] ??
          (throw StateError('the table has no vector for "$text"'));
    }
    return const [0, 0, 1];
  }

  @override
  Future<void> close() async {}
}
