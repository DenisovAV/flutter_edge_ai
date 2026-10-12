// `LiteRtEmbeddingPass` (.tflite) over a fake graph: the model's
// `maxInputTokens` is the compiled input's sequence length, an input over it
// is refused with the exact counts instead of being cut to fit, the graph's
// vector is copied through untouched (pooledFinal), and the graph is freed.
// No native library is opened.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

/// One id per character of prefix + text, wrapped in BOS 2 / EOS 1 — so a
/// test can count tokens by counting characters.
final class _CharTokenizer implements EmbeddingTokenizer {
  @override
  TokenizedInput encode(String prefix, String text) =>
      TokenizedInput(ids: [2, for (final c in '$prefix$text'.codeUnits) c, 1]);
}

Future<EmbeddingTokenizer> _charTokenizer(String _) async => _CharTokenizer();

final class _FakeGraph implements LiteRtEmbeddingGraph {
  _FakeGraph({this.sequenceLength = 8, this.vector = const [3, 4, 0, 0]});

  final int sequenceLength;
  final List<double> vector;
  String? openedPath;
  final runs = <List<int>>[];
  int closes = 0;

  @override
  ({int sequenceLength, int dimension}) open(String modelPath) {
    openedPath = modelPath;
    return (sequenceLength: sequenceLength, dimension: vector.length);
  }

  @override
  List<double> run(List<int> ids) {
    runs.add(ids);
    return vector;
  }

  @override
  void close() => closes++;
}

LiteRtEmbeddingPass _pass(_FakeGraph graph) => LiteRtEmbeddingPass(
  const LiteRtEmbeddingConfig(
    modelPath: '/m/gemma.tflite',
    tokenizerPath: '/m/t.model',
    tokenizerFactory: _charTokenizer,
  ),
  graph: graph,
);

void main() {
  test('load reports text, the dimension and the compiled sequence length as '
      'maxInputTokens', () async {
    final graph = _FakeGraph();
    final info = await _pass(graph).load();

    expect(graph.openedPath, '/m/gemma.tflite');
    expect(info.dimension, 4);
    expect(info.maxInputTokens, 8);
    expect(info.modalities, {EmbeddingModality.text});
  });

  test('an input exactly at the limit runs; one token more is refused with '
      'both counts and never reaches the graph', () async {
    final graph = _FakeGraph();
    final pass = _pass(graph);
    await pass.load();

    // BOS + 6 characters + EOS = 8.
    await pass.embed(EmbeddingInput.text('abcdef'), TaskType.none);
    expect(graph.runs.single, hasLength(8));

    await expectLater(
      pass.embed(EmbeddingInput.text('abcdefg'), TaskType.none),
      throwsA(
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'maxInputTokens', 8)
            .having((e) => e.actualTokens, 'actualTokens', 9),
      ),
    );
    expect(graph.runs, hasLength(1), reason: 'nothing was cut to fit');
  });

  test('the task prefix counts toward the limit', () async {
    final graph = _FakeGraph(sequenceLength: 40);
    final pass = _pass(graph);
    await pass.load();

    // 'title: none | text: ' is 20 characters: 20 + 1 + BOS + EOS = 23.
    await pass.embed(EmbeddingInput.text('a'), TaskType.retrievalDocument);
    expect(graph.runs.single, hasLength(23));

    // 'task: search result | query: ' is 29: + 10 + 2 = 41 > 40.
    await expectLater(
      pass.embed(EmbeddingInput.text('0123456789'), TaskType.retrievalQuery),
      throwsA(
        isA<EmbeddingInputTooLongException>().having(
          (e) => e.actualTokens,
          'actualTokens',
          41,
        ),
      ),
    );
  });

  test('the graph\'s vector is the embedding, copied verbatim (pooledFinal: '
      'no second pooling or normalisation)', () async {
    // Norm 5: a tokenLevel contract would re-normalise (or reject) it.
    final pass = _pass(_FakeGraph(vector: const [3, 4, 0, 0]));
    await pass.load();

    expect(await pass.embed(EmbeddingInput.text('x'), TaskType.none), [
      3,
      4,
      0,
      0,
    ]);
  });

  test('close frees the graph once, and is safe before load', () async {
    final graph = _FakeGraph();
    final pass = _pass(graph);
    await pass.load();
    await pass.close();
    await pass.close();
    expect(graph.closes, 1);

    final neverLoaded = _FakeGraph();
    await _pass(neverLoaded).close();
    expect(neverLoaded.closes, 0);
  });
}
