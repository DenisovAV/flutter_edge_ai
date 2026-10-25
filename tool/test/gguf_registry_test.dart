// Workspace integration: exercise both real providers without adding either
// engine to the other package's runtime or development dependency graph.
import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — verifies core's real registry with both optional engines.
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';

EmbeddingModelSpec _spec(String filename) => EmbeddingModelSpec(
  name: 'registry fixture',
  modelSource: ModelSource.network('https://models.test/$filename'),
);

void main() {
  final registry = EmbeddingRegistry.instance;
  setUp(registry.reset);
  tearDown(registry.reset);

  for (final llamaFirst in [false, true]) {
    test('real providers route by format, llamaFirst=$llamaFirst', () {
      const llama = LlamaEmbeddingBackend();
      const liteRt = LiteRtEmbeddingBackend();
      registry.registerAll(llamaFirst ? [llama, liteRt] : [liteRt, llama]);

      final gguf = _spec('embedding.GGUF');
      final litertlm = _spec('embedding.litertlm');
      expect(liteRt.canHandle(gguf), isFalse);
      expect(llama.canHandle(litertlm), isFalse);
      expect(registry.findFor(gguf), same(llama));
      expect(registry.findFor(litertlm), same(liteRt));
    });
  }
}
