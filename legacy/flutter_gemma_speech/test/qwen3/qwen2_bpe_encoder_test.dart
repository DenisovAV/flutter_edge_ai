// Golden-driven tests for the Qwen2 byte-level BPE encoder used by the
// Qwen3-TTS text frontend. The fixtures under test/golden/qwen3/ were
// generated with the real HuggingFace `tokenizers` library (see Task 0's
// golden generator) so they are the authoritative oracle for this encoder:
// any divergence here is a real bug, not a golden-file artifact.
//
// `tokenizer.json` is committed gzipped (~2 MB compressed, ~11 MB raw) --
// gunzip it in-memory via GZipCodec before handing the JSON string to
// Qwen2BpeEncoder.fromTokenizerJsonString. Production code loads the
// uncompressed `tokenizer.json` the model bundle installs at runtime via
// Qwen2BpeEncoder.fromTokenizerJson(path).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_speech/src/qwen3/qwen2_bpe_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

Qwen2BpeEncoder _loadGoldenEncoder() {
  final gz = File('test/golden/qwen3/tokenizer.json.gz').readAsBytesSync();
  final jsonBytes = GZipCodec().decode(gz);
  return Qwen2BpeEncoder.fromTokenizerJsonString(utf8.decode(jsonBytes));
}

void main() {
  late Qwen2BpeEncoder enc;

  setUpAll(() {
    enc = _loadGoldenEncoder();
  });

  test('encode reproduces HF tokenizer ids for the templated prompt', () {
    final g =
        jsonDecode(File('test/golden/qwen3/ids.json').readAsStringSync())
            as Map<String, dynamic>;
    final expected = (g['ids'] as List).cast<int>();
    expect(enc.encode(g['template'] as String), expected);
  });

  test('special tokens are atomic', () {
    expect(enc.encode('<|im_start|>'), [151644]);
    expect(enc.encode('<tts_pad>'), [151671]);
  });

  group('bpe_cases golden (diverse coverage)', () {
    final cases =
        jsonDecode(File('test/golden/qwen3/bpe_cases.json').readAsStringSync())
            as Map<String, dynamic>;

    for (final entry in cases.entries) {
      final text = entry.key;
      final expected = (entry.value as List).cast<int>();
      test('encode(${jsonEncode(text)}) == $expected', () {
        expect(enc.encode(text), expected);
      });
    }
  });

  test('fromTokenizerJson(path) loads an uncompressed tokenizer.json', () async {
    // Production entry point: write the golden fixture out uncompressed
    // once and load it via the file-path factory, to exercise the actual
    // path used at runtime (not just the in-memory string factory the
    // other tests use for speed).
    final gz = File('test/golden/qwen3/tokenizer.json.gz').readAsBytesSync();
    final jsonBytes = GZipCodec().decode(gz);
    final tmp = File(
      '${Directory.systemTemp.path}/qwen3_tokenizer_test_${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await tmp.writeAsBytes(jsonBytes);
    try {
      final fileEncoder = await Qwen2BpeEncoder.fromTokenizerJson(tmp.path);
      expect(fileEncoder.encode('<|im_start|>'), [151644]);
      expect(fileEncoder.encode('Hello, world!'), [9707, 11, 1879, 0]);
    } finally {
      await tmp.delete();
    }
  });
}
