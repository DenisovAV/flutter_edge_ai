@TestOn('vm')
library;

// Differential test: this package's Gemma tokenization against Google's
// SentencePiece, row by row.
//
// test/fixtures/eg1_sentencepiece_reference.json holds a corpus (the 40 W1
// strings, HTML / markdown / code with Gemma's user-defined tag pieces in
// every position, tag-like strings that are not pieces, the special and
// control pieces, Gemma's chat and image markers as literal text, whitespace
// runs, CJK, emoji, combining marks — 253 strings, 31 of them also under the
// eight non-empty TaskType prefixes) and the ids the
// Python `sentencepiece` package returns for each, from the catalog's
// EmbeddingGemma 1 `sentencepiece.model`. Every row must come out of
// `encodeForEmbedding` — and out of the registry route the `.tflite` pass
// takes — as `[2, ...reference, 1]`.
//
// The `tokenizer.json` loader is checked the same way against
// onnx-community/embeddinggemma-300m-ONNX's pair (`tokenizer.json` and the
// `tokenizer.model` the reference was generated from). That file is 20 MB and
// not committed, so that group runs only when EG1_ONNX_TOKENIZER_DIR names a
// directory holding it (ungated):
//   mkdir -p /tmp/eg1-onnx && for f in tokenizer.json tokenizer.model; do
//     curl -L -o /tmp/eg1-onnx/$f https://huggingface.co/onnx-community/\
//   embeddinggemma-300m-ONNX/resolve/5090578d9565bb06545b4552f76e6bc2c93e4a66/$f
//   done
//   EG1_ONNX_TOKENIZER_DIR=/tmp/eg1-onnx flutter test \
//     test/sentencepiece_reference_test.dart
//
// Regenerate the fixtures with tool/generate_sentencepiece_reference.py (its
// header says how); never edit them by hand.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' show TaskType;
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_edge_ai_embeddings/src/sentencepiece_model_proto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Relative to this package's root (`flutter test`'s working directory).
const _eg1Fixture = 'test/fixtures/eg1_sentencepiece_reference.json';
const _eg1Model =
    '../flutter_edge_ai/example/assets/models/sentencepiece.model';
const _onnxFixture = 'test/fixtures/eg1_onnx_sentencepiece_reference.json';
const _onnxDirVariable = 'EG1_ONNX_TOKENIZER_DIR';

typedef _Row = ({String name, String task, String text, List<int> ids});

final class _Fixture {
  _Fixture._(this.json, this.rows);

  factory _Fixture.read(String path) {
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final rows = [
      for (final raw in json['rows']! as List<Object?>)
        if (raw case {
          'name': final String name,
          'prefix': final String task,
          'text': final String text,
          'ids': final List<Object?> ids,
        })
          (name: name, task: task, text: text, ids: ids.cast<int>())
        else
          throw FormatException('malformed row in $path: $raw'),
    ];
    return _Fixture._(json, rows);
  }

  final Map<String, Object?> json;
  final List<_Row> rows;

  Map<String, String> get prefixes =>
      (json['prefixes']! as Map<String, Object?>).cast<String, String>();

  Map<String, Object?> get tokenizer =>
      json['tokenizer']! as Map<String, Object?>;
}

/// Runs [encode] over every row and fails once, listing every row that
/// differs from `[2, ...reference, 1]`.
void _expectReference(
  _Fixture fixture,
  List<int> Function(String prefix, String text) encode, {
  required String route,
}) {
  final prefixes = fixture.prefixes;
  final misses = <String>[];
  for (final row in fixture.rows) {
    final want = [2, ...row.ids, 1];
    final got = encode(prefixes[row.task]!, row.text);
    if (!_sameIds(got, want)) {
      misses.add(
        '${row.name} [${row.task}] ${jsonEncode(row.text)}\n'
        '    reference: $want\n'
        '    $route: $got',
      );
    }
  }
  if (misses.isEmpty) return;
  fail(
    '$route differs from SentencePiece on ${misses.length} of '
    '${fixture.rows.length} rows:\n${misses.take(25).join('\n')}'
    '${misses.length > 25 ? '\n  … and ${misses.length - 25} more' : ''}',
  );
}

bool _sameIds(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _expectFixturePrefixesAreTaskTypes(_Fixture fixture) {
  expect(
    fixture.prefixes,
    {for (final type in TaskType.values) type.name: type.prefix},
    reason:
        'TaskType prefixes changed: regenerate the W1 golden, then '
        'tool/generate_sentencepiece_reference.py',
  );
}

void main() {
  group('EmbeddingGemma 1 sentencepiece.model (the catalog tokenizer)', () {
    final fixture = _Fixture.read(_eg1Fixture);

    test('the fixture covers several hundred rows and every TaskType', () {
      expect(fixture.rows.length, greaterThan(400));
      _expectFixturePrefixesAreTaskTypes(fixture);
      expect(
        fixture.rows.map((r) => r.task).toSet(),
        TaskType.values.map((t) => t.name).toSet(),
      );
    });

    test('the fixture was generated from this file: the same piece and '
        'user-defined piece counts', () {
      final model = SentencePieceModelProto.parse(
        File(_eg1Model).readAsBytesSync(),
      );
      expect(model.pieceCount, fixture.tokenizer['pieces']);
      expect(model.userDefined.length, fixture.tokenizer['userDefinedPieces']);
    });

    test('encodeForEmbedding(loadEmbeddingTokenizer(.model)) is '
        '[2, ...SentencePiece, 1] for every row', () async {
      final tokenizer = await loadEmbeddingTokenizer(_eg1Model);
      _expectReference(
        fixture,
        (prefix, text) => encodeForEmbedding(tokenizer, prefix, text),
        route: 'encodeForEmbedding',
      );
    });

    test('the registry route the .tflite pass takes '
        '(GemmaEmbeddingTokenizers) gives the same ids', () async {
      final tokenizer = await const GemmaEmbeddingTokenizers().factory(
        _eg1Model,
      );
      _expectReference(
        fixture,
        (prefix, text) => tokenizer.encode(prefix, text).ids,
        route: 'GemmaEmbeddingTokenizers',
      );
    });
  });

  group('onnx-community/embeddinggemma-300m-ONNX tokenizer.json and '
      'tokenizer.model (opt-in: $_onnxDirVariable)', () {
    final fixture = _Fixture.read(_onnxFixture);
    final dir = Platform.environment[_onnxDirVariable];

    String? fileOrSkip(String name) {
      if (dir == null || dir.isEmpty) {
        markTestSkipped(
          '$_onnxDirVariable is not set: the 20 MB tokenizer.json is not '
          'committed. See this file\'s header for the download.',
        );
        return null;
      }
      final path = '$dir/$name';
      if (!File(path).existsSync()) fail('$path does not exist');
      return path;
    }

    test('the fixture\'s prefixes are the TaskType prefixes', () {
      _expectFixturePrefixesAreTaskTypes(fixture);
    });

    test('tokenizer.json through the registry route is '
        '[2, ...SentencePiece(tokenizer.model), 1] for every row', () async {
      final path = fileOrSkip('tokenizer.json');
      if (path == null) return;
      final tokenizer = await const GemmaEmbeddingTokenizers().factory(path);
      _expectReference(
        fixture,
        (prefix, text) => tokenizer.encode(prefix, text).ids,
        route: 'tokenizer.json',
      );
    });

    test('tokenizer.model through the registry route matches too', () async {
      final path = fileOrSkip('tokenizer.model');
      if (path == null) return;
      final tokenizer = await const GemmaEmbeddingTokenizers().factory(path);
      _expectReference(
        fixture,
        (prefix, text) => tokenizer.encode(prefix, text).ids,
        route: 'tokenizer.model',
      );
    });
  });
}
