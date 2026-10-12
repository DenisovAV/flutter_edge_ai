// TokenEmbeddingPass (R5 D3, §2.2.2): the template the .tflite and ONNX passes
// share — tokenizer from its path, prefix through the adapter, the overflow
// check counting prefix + BOS + EOS, finalisation with the effective mask, and
// close on every path.

import 'dart:typed_data';

import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/forward_result.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/embedding/token_embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/tokenizer_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// One id per character of prefix + text, wrapped in BOS 2 / EOS 1 — so the
/// id count is `prefix.length + text.length + 2`, easy to aim at a limit.
final class _CharTokenizer implements EmbeddingTokenizer {
  _CharTokenizer(this.path);

  final String path;
  final prefixes = <String>[];

  @override
  TokenizedInput encode(String prefix, String text) {
    prefixes.add(prefix);
    final ids = [2, ...'$prefix$text'.codeUnits, 1];
    return TokenizedInput(
      ids: ids,
      attentionMask: List<int>.filled(ids.length, 1),
    );
  }
}

_CharTokenizer? _lastTokenizer;

Future<EmbeddingTokenizer> _charTokenizerFactory(String path) async =>
    _lastTokenizer = _CharTokenizer(path);

Future<EmbeddingTokenizer> _failingTokenizerFactory(String path) async =>
    throw StateError('no tokenizer at $path');

final class _FakePass extends TokenEmbeddingPass {
  _FakePass({
    this.maxInputTokens,
    this.contract = EmbeddingOutputContract.pooledFinal,
    this.result,
    this.openThrows = false,
    EmbeddingTokenizerFactory tokenizerFactory = _charTokenizerFactory,
  }) : super(tokenizerPath: '/tok.model', tokenizerFactory: tokenizerFactory);

  final int? maxInputTokens;
  final EmbeddingOutputContract contract;
  final ForwardResult? result;
  final bool openThrows;
  final log = <String>[];
  final runs = <TokenizedInput>[];

  @override
  Future<TokenPassGraph> openGraph() async {
    log.add('open');
    if (openThrows) throw StateError('graph refused to open');
    return TokenPassGraph(
      dimension: 2,
      outputContract: contract,
      maxInputTokens: maxInputTokens,
    );
  }

  @override
  Future<ForwardResult> runTokens(TokenizedInput input) async {
    log.add('run');
    runs.add(input);
    return result ?? const ForwardResult(values: [3, 4], shape: [1, 2]);
  }

  @override
  Future<void> closeGraph() async => log.add('close');
}

void main() {
  group('load', () {
    test(
      'builds the tokenizer from its path, opens the graph, reports text',
      () async {
        final pass = _FakePass(maxInputTokens: 64);
        final info = await pass.load();

        expect(_lastTokenizer!.path, '/tok.model');
        expect(pass.log, ['open']);
        expect(info.dimension, 2);
        expect(info.maxInputTokens, 64);
        expect(info.modalities, {EmbeddingModality.text});
        expect(info.imageFormats, isEmpty);
        expect(info.combinedInputs, isFalse);
      },
    );

    test('a graph that declares no limit reports null', () async {
      final info = await _FakePass().load();
      expect(info.maxInputTokens, isNull);
    });
  });

  group('embed', () {
    test('text gets the task prefix through the tokenizer', () async {
      final pass = _FakePass();
      await pass.load();
      await pass.embed(EmbeddingInput.text('hi'), TaskType.codeRetrieval);

      expect(_lastTokenizer!.prefixes, ['task: code retrieval | query: ']);
      expect(pass.runs.single.ids.length, 30 + 2 + 2);
    });

    test(
      'the limit counts prefix, BOS and EOS: max passes, max+1 throws',
      () async {
        // TaskType.none adds no prefix: 'abc' → [2, a, b, c, 1] = 5 ids.
        final pass = _FakePass(maxInputTokens: 5);
        await pass.load();

        await pass.embed(EmbeddingInput.text('abc'), TaskType.none);
        await expectLater(
          pass.embed(EmbeddingInput.text('abcd'), TaskType.none),
          throwsA(
            isA<EmbeddingInputTooLongException>()
                .having((e) => e.maxInputTokens, 'maxInputTokens', 5)
                .having((e) => e.actualTokens, 'actualTokens', 6),
          ),
        );
        expect(pass.runs, hasLength(1), reason: 'an overflow never runs');
      },
    );

    test('the prefix alone can overflow', () async {
      // 'title: none | text: ' is 20 characters: 20 + BOS + EOS = 22.
      final pass = _FakePass(maxInputTokens: 21);
      await pass.load();

      await expectLater(
        pass.embed(EmbeddingInput.text(''), TaskType.retrievalDocument),
        throwsA(
          isA<EmbeddingInputTooLongException>().having(
            (e) => e.actualTokens,
            'actualTokens',
            22,
          ),
        ),
      );
    });

    test('no limit, no check', () async {
      final pass = _FakePass();
      await pass.load();
      await pass.embed(EmbeddingInput.text('x' * 10000), TaskType.none);
      expect(pass.runs.single.ids, hasLength(10002));
    });

    test('pooledFinal results are returned verbatim', () async {
      final pass = _FakePass();
      await pass.load();
      expect(await pass.embed(EmbeddingInput.text('a'), TaskType.none), [
        3.0,
        4.0,
      ]);
    });

    test(
      'tokenLevel uses the mask the graph echoed over the tokenizer mask',
      () async {
        // The graph padded to 3 positions and says the third is padding; the
        // tokenizer's own mask (all ones, for 3 ids of 'a' + BOS/EOS) would pool
        // the lopsided padding row in.
        final pass = _FakePass(
          contract: EmbeddingOutputContract.tokenLevel,
          result: const ForwardResult(
            values: [1, 0, 0, 1, 999, 0],
            shape: [1, 3, 2],
            attentionMask: [1, 1, 0],
          ),
        );
        await pass.load();
        final vector = await pass.embed(
          EmbeddingInput.text('a'),
          TaskType.none,
        );
        expect(vector[0], closeTo(0.70710678, 1e-6));
        expect(vector[1], closeTo(0.70710678, 1e-6));
      },
    );

    test('tokenLevel falls back to the tokenizer mask', () async {
      final pass = _FakePass(
        contract: EmbeddingOutputContract.tokenLevel,
        result: const ForwardResult(
          values: [1, 0, 0, 1, 1, 1],
          shape: [1, 3, 2],
        ),
      );
      await pass.load();
      final vector = await pass.embed(EmbeddingInput.text('a'), TaskType.none);
      // mean([1,0],[0,1],[1,1]) = [2/3, 2/3] → normalised.
      expect(vector[0], closeTo(0.70710678, 1e-6));
    });

    test('media inputs are refused (text-only template)', () async {
      final pass = _FakePass();
      await pass.load();
      await expectLater(
        pass.embed(
          EmbeddingInput.image(Uint8List.fromList([1])),
          TaskType.none,
        ),
        throwsStateError,
      );
    });

    test('embed before load is refused', () async {
      await expectLater(
        _FakePass().embed(EmbeddingInput.text('a'), TaskType.none),
        throwsStateError,
      );
    });
  });

  group('close', () {
    test('frees the graph once', () async {
      final pass = _FakePass();
      await pass.load();
      await pass.close();
      await pass.close();
      expect(pass.log, ['open', 'close']);
    });

    test(
      'a pass that never loaded closes without touching the graph',
      () async {
        final pass = _FakePass();
        await pass.close();
        expect(pass.log, isEmpty);
      },
    );

    test('a graph that failed to open is still closed', () async {
      final pass = _FakePass(openThrows: true);
      await expectLater(pass.load(), throwsStateError);
      await pass.close();
      expect(pass.log, ['open', 'close']);
    });

    test('a tokenizer that failed to build leaves no graph to close', () async {
      final pass = _FakePass(tokenizerFactory: _failingTokenizerFactory);
      await expectLater(pass.load(), throwsStateError);
      await pass.close();
      expect(pass.log, isEmpty);
    });
  });
}
