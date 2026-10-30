// The two places speech compiles a LiteRT graph (SttCore.load and
// loadLiteRtGraph, which every TTS core goes through) need a real native
// library to run, so a VM test cannot load a model through them. This holds
// their source to the rules that the GPU-options tests rely on (#747): every
// set of compilation options gets its accelerator through
// configureSpeechAccelerator (which adds the fp32 GPU options for
// speech-to-text only), never through
// a direct setOptionsHardwareAccelerators call, every compile failure is
// taken through takeCompiledModel, and the seq2seq decoder is runGreedyDecode
// over a native step that only copies its output row, unlocked on every path.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

int _count(String source, String pattern) =>
    RegExp(pattern).allMatches(source).length;

void main() {
  final sources = {
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>())
      // Keyed with '/' on every host, so the paths below match on Windows too,
      if (file.path.endsWith('.dart'))
        // and with '\n' line ends, so a CRLF checkout matches too.
        file.path.replaceAll(r'\', '/'): file.readAsStringSync().replaceAll(
          '\r\n',
          '\n',
        ),
  };

  test('only configureSpeechAccelerator sets the accelerator', () {
    final direct = {
      for (final MapEntry(:key, :value) in sources.entries)
        if (_count(value, r'setOptionsHardwareAccelerators') > 0)
          key: _count(value, r'setOptionsHardwareAccelerators'),
    };
    // The one tear-off inside configureSpeechAccelerator itself.
    expect(direct, {'lib/src/litert/litert_graph.dart': 1});
    expect(
      sources['lib/src/litert/litert_graph.dart'],
      contains('setAccelerators: bindings.setOptionsHardwareAccelerators,'),
    );
  });

  test('every createOptions is followed by configureSpeechAccelerator', () {
    final checked = <String>[];
    for (final MapEntry(:key, :value) in sources.entries) {
      final created = _count(value, r'\.createOptions\(');
      if (created == 0) continue;
      checked.add(key);
      expect(
        _count(value, r'configureSpeechAccelerator\(\s*bindings,'),
        created,
        reason: '$key creates options without configureSpeechAccelerator',
      );
    }
    expect(
      checked,
      unorderedEquals([
        'lib/src/litert/litert_graph.dart',
        'lib/src/litert/stt_core.dart',
      ]),
    );
  });

  test('only speech-to-text asks for the fp32 GPU options', () {
    // SttCore.load compiles the speech-to-text graph; loadLiteRtGraph compiles
    // every text-to-speech graph, which keeps LiteRT's GPU defaults.
    expect(
      _count(
        sources['lib/src/litert/stt_core.dart']!,
        r'configureSpeechAccelerator\([^;]*fp32OnGpu: true,',
      ),
      1,
    );
    final graph = sources['lib/src/litert/litert_graph.dart']!;
    final load = graph.substring(graph.indexOf('LoadedGraph loadLiteRtGraph('));
    expect(
      _count(load, r'configureSpeechAccelerator\([^;]*fp32OnGpu: false,'),
      1,
    );
    final ttsLoaders = {
      for (final MapEntry(:key, :value) in sources.entries)
        if (value.contains('loadLiteRtGraph(') &&
            key != 'lib/src/litert/litert_graph.dart')
          key,
    };
    expect(
      ttsLoaders,
      unorderedEquals([
        'lib/src/litert/tts_core.dart',
        'lib/src/litert/inflect_tts_core.dart',
        'lib/src/qwen3/qwen3_tts_core.dart',
      ]),
    );
  });

  test('every compile result goes through takeCompiledModel', () {
    final checked = <String>[];
    for (final MapEntry(:key, :value) in sources.entries) {
      final compiles = _count(value, r'\.createCompiledModel\(');
      if (compiles == 0) continue;
      checked.add(key);
      expect(
        _count(value, r'takeCompiledModel\(\s*compiledPtr,\s*status,'),
        compiles,
        reason: '$key compiles a graph without takeCompiledModel',
      );
    }
    expect(
      checked,
      unorderedEquals([
        'lib/src/litert/litert_graph.dart',
        'lib/src/litert/stt_core.dart',
      ]),
    );
  });

  test('the seq2seq decoder is runGreedyDecode over a copied output row', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final loop = stt.substring(
      stt.indexOf('List<int> _decodeLoop('),
      stt.indexOf('Float32List _readDecoderRow('),
    );
    // The token is picked in runGreedyDecode (tested on its own: NaN check,
    // suppression step, stop rule); the native step only hands it the row.
    expect(_count(loop, r'return runGreedyDecode\('), 1);
    expect(loop, isNot(contains('greedyDecodeStep(')));
    expect(loop, isNot(contains('argmax(')));
    expect(_count(loop, r'return _readDecoderRow\('), 1);
    expect(
      _count(
        stt,
        r'greedyDecodeStep\(\s*decoderRow\(generated\),\s*step: step,',
      ),
      1,
    );
  });

  test('SttCore hands runGreedyDecode its own EOS and suppression', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final call = stt.substring(stt.indexOf('return runGreedyDecode('));
    final args = call.substring(0, call.indexOf('decoderRow:'));
    // Whisper's EOS is not moonshine's 2, and its suppression is what blocks
    // timestamps and step-zero tokens; a literal here breaks one of them.
    expect(args, contains('eosId: _eosId,'));
    expect(args, contains('suppression: _resolvedSuppression,'));
    expect(args, contains('maxTokens: maxTokens,'));
    expect(args, contains('promptIds: promptIds,'));
    // The row of the token just written, copied in full and nothing more.
    expect(_count(call, r'row: len - 1,'), 1);
  });

  test('the decoder row is read with the buffer unlocked on every path', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final read = stt.substring(
      stt.indexOf('Float32List _readDecoderRow('),
      stt.indexOf('List<int> _ctcDecode('),
    );
    final locked = read.indexOf('.lockTensorBuffer(');
    final copied = read.indexOf('copied = logits.sublist(');
    final onFailure = read.indexOf('_bindings.unlockTensorBuffer(buffer);');
    final rethrown = read.indexOf('rethrow;');
    final unlocked = read.indexOf(
      '.unlockTensorBuffer(buffer)\n          .check(',
    );
    final returned = read.indexOf('return copied;');
    for (final at in [
      locked,
      copied,
      onFailure,
      rethrown,
      unlocked,
      returned,
    ]) {
      expect(at, isNonNegative, reason: read);
    }
    // lock, copy, (on a failed copy: unlock, rethrow), unlock, return.
    expect(locked, lessThan(copied));
    expect(copied, lessThan(onFailure));
    expect(onFailure, lessThan(rethrown));
    expect(rethrown, lessThan(unlocked));
    expect(unlocked, lessThan(returned));
    expect(_count(read, r'\.unlockTensorBuffer\('), 2);
    expect(read, isNot(contains('if (')));
    // Read lock, checked; the copy is exactly row [row]; any throwable is
    // caught for the unlock, Errors (RangeError) included.
    expect(read, contains('kLiteRtTensorBufferLockModeRead'));
    expect(read, contains(".check('LiteRtLockTensorBuffer(decode out)')"));
    expect(
      read,
      contains(
        'copied = logits.sublist(row * vocabSize, (row + 1) * vocabSize);',
      ),
    );
    expect(read, contains('} catch (_) {'));
  });
}
