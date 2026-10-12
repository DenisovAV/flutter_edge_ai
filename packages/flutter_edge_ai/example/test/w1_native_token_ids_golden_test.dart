// W1 (R5 §7): the token ids NATIVE EmbeddingGemma 1 runs for a fixed set of
// 40 strings under each of the 9 TaskType prefixes, written to
// integration_test/goldens/w1_eg1_native_token_ids.dart. The web drive suite
// (integration_test/web_embeddings_test.dart) asserts that the LiteRT.js
// bundle's `tokenizeLiteRtText(prefix + text)` returns exactly these ids, and
// records what bundle API v1 ran for the two prefixes it knew.
//
// "Native" is the path the `.tflite` pass takes: core's tokenizer registry
// hands it `GemmaEmbeddingTokenizers().factory`, which routes a SentencePiece
// `.model` file to the Gemma adapter — `[2, ...ids(prefix + text), 1]`, the
// ids SentencePiece produces, user-defined pieces such as `</div>` kept whole
// (`encodeForEmbedding`; flutter_edge_ai_embeddings'
// test/sentencepiece_reference_test.dart holds it to the Python reference) —
// and the pass runs those ids. The tokenizer is the
// example's `assets/models/sentencepiece.model`, byte-identical to
// litert-community/embeddinggemma-300m@29888fce's `sentencepiece.model` (the
// catalog's EG1 tokenizer): its SHA-256 below is the oid in that file's Git LFS
// pointer, whose Git object id is 3e7e7278ad87b05318db6478efeccbe3746f1a14 in
// the Hugging Face tree at that revision.
//
// Every run checks the golden against the tokenizer as it is now. To write it
// (never on CI):
//   cd packages/flutter_edge_ai/example
//   UPDATE_GOLDENS=1 flutter test test/w1_native_token_ids_golden_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_test/flutter_test.dart';

const _tokenizerAsset = 'assets/models/sentencepiece.model';

/// SHA-256 of [_tokenizerAsset] = the LFS oid of the catalog's EG1 tokenizer.
const _tokenizerSha256 =
    'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7';

const _huggingFaceFile =
    'litert-community/embeddinggemma-300m@'
    '29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model';

const _goldenPath = 'integration_test/goldens/w1_eg1_native_token_ids.dart';

/// The fixed set (R5 §7): ASCII, CJK, emoji, combining marks, code, leading
/// and trailing spaces, empty. Non-ASCII is escaped so the source says which
/// code points (precomposed or combining) each string holds.
const w1Strings = <(String, String)>[
  ('empty', ''),
  ('ascii word', 'hello'),
  ('ascii greeting', 'Hello, world!'),
  ('ascii pangram', 'The quick brown fox jumps over the lazy dog.'),
  ('ascii question', 'Which planet is known as the Red Planet?'),
  ('ascii case', 'UPPER lower MiXeD case'),
  ('numbers', 'numbers 0 1 42 3.14159 1e-9 -7 1,000,000'),
  (
    'email and url',
    'email@example.com https://flutteredge.ai/docs?q=1&x=2#top',
  ),
  ('punctuation', 'punctuation: !?.,;:\'"()[]{}<>/\\|@#\$%^&*-_+=~`'),
  ('leading space', ' leading space'),
  ('trailing space', 'trailing space '),
  ('spaces both sides', '  both sides  '),
  ('whitespace only', '   '),
  ('inner spaces', 'multiple   inner    spaces'),
  ('tabs', 'tab\tseparated\ttext'),
  ('newlines', 'line one\nline two\n'),
  ('newline only', '\n'),
  ('chinese', '你好，世界'),
  ('japanese', '日本語のテキストを埋め込む'),
  ('korean', '한국어 문장입니다'),
  ('cjk mixed', '混合 mixed 文本 text'),
  ('fullwidth', 'ＦＵＬＬＷＩＤＴＨ ｔｅｘｔ １２３'),
  ('emoji alone', '\u{1f600}'),
  ('emoji in text', 'I love pizza \u{1f355}\u{1f355}!'),
  ('emoji zwj', 'family \u{1f468}‍\u{1f469}‍\u{1f467}‍\u{1f466} ZWJ sequence'),
  (
    'emoji flags and skin tone',
    'flags \u{1f1fa}\u{1f1e6}\u{1f1ef}\u{1f1f5} and skin tone \u{1f44d}\u{1f3fd}',
  ),
  ('precomposed e acute', 'café'),
  ('combining acute', 'café'),
  ('precomposed angstrom', 'Ångström'),
  ('combining ring and diaeresis', 'Ångström'),
  ('latin diacritics', 'naïve résumé coöperate'),
  ('devanagari', 'नमस्ते दुनिया'),
  ('arabic', 'مرحبا بالعالم'),
  ('cyrillic and greek', 'Привет, мир! Γειά σου Κόσμε'),
  ('python code', 'def add(a, b):\n    return a + b'),
  ('c code', 'for (int i = 0; i < n; i++) { sum += xs[i]; }'),
  ('dart code', 'final x = await FlutterEdgeAi.getActiveEmbedder();'),
  ('sql', 'SELECT * FROM docs WHERE id = 42;'),
  ('html', '<div class="note">Hi &amp; bye</div>'),
  (
    'paragraph',
    'Retrieval-augmented generation splits documents into chunks, embeds each chunk once, and stores the vectors; at query time the question is embedded with the query prefix and the nearest chunks are handed to the language model as context.',
  ),
];

/// A text far over EG1 seq256's 256 ids under any prefix: the web suite
/// expects `EmbeddingInputTooLongException(maxInputTokens: 256, actualTokens:
/// <this count>)` for it.
final _overflowText = 'The quick brown fox jumps over the lazy dog. ' * 30;
const _overflowTaskType = TaskType.retrievalDocument;

void main() {
  test('W1: the golden holds the native ids of all 40 strings under all 9 '
      'prefixes, from the catalog\'s EG1 tokenizer', () async {
    expect(w1Strings, hasLength(40));
    expect(
      w1Strings.map((s) => s.$1).toSet(),
      hasLength(40),
      reason: 'names key the web suite\'s failure messages',
    );

    final bytes = File(_tokenizerAsset).readAsBytesSync();
    expect(
      sha256.convert(bytes).toString(),
      _tokenizerSha256,
      reason: '$_tokenizerAsset is no longer the catalog\'s EG1 tokenizer',
    );

    // The registry route the native .tflite pass takes.
    final tokenizer = await const GemmaEmbeddingTokenizers().factory(
      _tokenizerAsset,
    );
    List<int> idsFor(TaskType type, String text) =>
        tokenizer.encode(type.prefix, text).ids;

    final ids = {
      for (final type in TaskType.values)
        type: [for (final (_, text) in w1Strings) idsFor(type, text)],
    };
    for (final perString in ids.values) {
      for (final row in perString) {
        expect(row.first, 2, reason: 'Gemma BOS');
        expect(row.last, 1, reason: 'Gemma EOS');
      }
    }
    final overflowCount = idsFor(_overflowTaskType, _overflowText).length;
    expect(overflowCount, greaterThan(256));

    _expectGolden(_render(ids, overflowCount));
  });
}

void _expectGolden(String actual) {
  final golden = File(_goldenPath);
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    if ((Platform.environment['CI'] ?? '').isNotEmpty) {
      fail(
        'UPDATE_GOLDENS=1 is refused while CI is set: a regenerated golden '
        'always matches. Regenerate locally and commit the reviewed diff.',
      );
    }
    golden.writeAsStringSync(actual);
    return;
  }
  expect(
    golden.existsSync(),
    isTrue,
    reason: 'Missing $_goldenPath. Run with UPDATE_GOLDENS=1 to create it.',
  );
  final expected = golden.readAsStringSync();
  if (actual == expected) return;
  final now = actual.split('\n');
  final was = expected.split('\n');
  final shorter = now.length < was.length ? now.length : was.length;
  var line = 0;
  while (line < shorter && now[line] == was[line]) {
    line++;
  }
  fail(
    'The native ids no longer match $_goldenPath, first at line ${line + 1}:\n'
    '  golden: ${line < was.length ? was[line] : '<end>'}\n'
    '  now:    ${line < now.length ? now[line] : '<end>'}\n'
    'If the tokenizer changed on purpose, regenerate with UPDATE_GOLDENS=1 '
    'and re-run W1 on the web.',
  );
}

/// The golden: a Dart file holding one JSON document, so the browser suite
/// can import it (a web test cannot read files). ASCII only — every other
/// code point is a \u escape, so NFC and NFD forms stay visibly distinct —
/// and no single quote, so the raw string cannot end early. One id row per
/// line, so a diff names the string that changed.
String _render(Map<TaskType, List<List<int>>> ids, int overflowCount) {
  final b = StringBuffer()
    ..writeln(
      '// GENERATED by test/w1_native_token_ids_golden_test.dart — do not '
      'edit.',
    )
    ..writeln(
      '// Regenerate: UPDATE_GOLDENS=1 flutter test '
      'test/w1_native_token_ids_golden_test.dart',
    )
    ..writeln('//')
    ..writeln(
      '// W1 (R5 §7): native EmbeddingGemma 1 token ids, '
      '[2, ...encode(taskType.prefix + text), 1],',
    )
    ..writeln(
      '// for 40 strings x 9 TaskType prefixes. Read by '
      'web_embeddings_test.dart.',
    )
    ..writeln('library;')
    ..writeln()
    ..writeln("const w1NativeTokenIdsJson = r'''")
    ..writeln('{')
    ..writeln('"schema": 1,')
    ..writeln('"tokenizer": {')
    ..writeln('  "asset": ${_json(_tokenizerAsset)},')
    ..writeln('  "sha256": ${_json(_tokenizerSha256)},')
    ..writeln('  "huggingFace": ${_json(_huggingFaceFile)},')
    ..writeln(
      '  "ids": ${_json('GemmaEmbeddingTokenizers -> Gemma SentencePiece '
      '(dart_sentencepiece_tokenizer 1.4.1 + the user-defined pass of '
      'flutter_edge_ai_embeddings): [2, ...ids(prefix + text), 1]')}',
    )
    ..writeln('},')
    ..writeln('"prefixes": {');
  for (final (i, type) in TaskType.values.indexed) {
    final comma = i == TaskType.values.length - 1 ? '' : ',';
    b.writeln('  ${_json(type.name)}: ${_json(type.prefix)}$comma');
  }
  b
    ..writeln('},')
    ..writeln('"strings": [');
  for (final (i, (name, text)) in w1Strings.indexed) {
    final comma = i == w1Strings.length - 1 ? '' : ',';
    b.writeln('  [${_json(name)}, ${_json(text)}]$comma');
  }
  b
    ..writeln('],')
    ..writeln('"nativeIds": {');
  for (final (t, type) in TaskType.values.indexed) {
    b.writeln('  ${_json(type.name)}: [');
    final rows = ids[type]!;
    for (final (i, row) in rows.indexed) {
      final comma = i == rows.length - 1 ? '' : ',';
      b.writeln('    [${row.join(', ')}]$comma');
    }
    b.writeln('  ]${t == TaskType.values.length - 1 ? '' : ','}');
  }
  b
    ..writeln('},')
    ..writeln('"overflow": {')
    ..writeln('  "taskType": ${_json(_overflowTaskType.name)},')
    ..writeln('  "text": ${_json(_overflowText)},')
    ..writeln('  "nativeTokenCount": $overflowCount')
    ..writeln('}')
    ..writeln('}')
    ..writeln("''';");
  final rendered = b.toString();
  // The web suite reads it with jsonDecode; prove it parses back to the same
  // strings before writing it.
  final start = rendered.indexOf("r'''") + 4;
  final decoded =
      jsonDecode(rendered.substring(start, rendered.lastIndexOf("'''")))
          as Map<String, Object?>;
  final strings = decoded['strings']! as List<Object?>;
  for (final (i, (_, text)) in w1Strings.indexed) {
    expect((strings[i]! as List<Object?>)[1], text);
  }
  return rendered;
}

/// A JSON string literal with everything outside printable ASCII — and the
/// single quote — as a \u escape (surrogate pairs above the BMP).
String _json(String s) {
  final out = StringBuffer('"');
  for (final unit in s.codeUnits) {
    if (unit == 0x22) {
      out.write(r'\"');
    } else if (unit == 0x5c) {
      out.write(r'\\');
    } else if (unit >= 0x20 && unit < 0x7f && unit != 0x27) {
      out.writeCharCode(unit);
    } else {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
  }
  out.write('"');
  return out.toString();
}
