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

/// Where [pattern] first matches in [source], or -1.
int _at(String source, String pattern) =>
    RegExp(pattern).firstMatch(source)?.start ?? -1;

/// [source] from its one match of [start] up to the first match of [end]
/// after it; fails when [start] does not match exactly once.
String _slice(String source, String start, String end) {
  expect(_count(source, start), 1, reason: 'anchor $start');
  final rest = source.substring(_at(source, start));
  final to = _at(rest, end);
  expect(to, isPositive, reason: 'anchor $end');
  return rest.substring(0, to);
}

/// [source] without its `//` comments (doc comments included), so a
/// commented-out copy of a line never satisfies a check. A `//` counts as a
/// comment at the start of a line or after a space or tab: the `//` of
/// `https://` in a string does not.
String _withoutComments(String source) =>
    source.replaceAll(RegExp(r'(^|[ \t])//.*$', multiLine: true), r'$1');

void main() {
  // Keyed with '/' on every host and read with '\n' line ends and no
  // comments, so the paths and patterns below match on a Windows or CRLF
  // checkout too.
  final sources = {
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>())
      if (file.path.endsWith('.dart'))
        file.path.replaceAll(r'\', '/'): _withoutComments(
          file.readAsStringSync().replaceAll('\r\n', '\n'),
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
    final loop = _slice(
      stt,
      r'List<int> _decodeLoop\(',
      r'Float32List _readDecoderRow\(',
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
        r'greedyDecodeStep\(\s*decoderRow\(generated\),\s*step:\s*step,',
      ),
      1,
    );
  });

  test('SttCore hands the decoder its own EOS, suppression, mask and sizes', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final call = _slice(
      stt,
      r'return runGreedyDecode\(',
      r'Float32List _readDecoderRow\(',
    );
    final args = call.substring(0, _at(call, r'decoderRow:'));
    // Whisper's EOS is not moonshine's 2, and its suppression is what blocks
    // timestamps and step-zero tokens; a literal here breaks one of them.
    expect(_count(args, r'eosId:\s*_eosId,'), 1);
    expect(_count(args, r'suppression:\s*_resolvedSuppression,'), 1);
    expect(_count(args, r'maxTokens:\s*maxTokens,'), 1);
    expect(_count(args, r'promptIds:\s*promptIds,'), 1);
    // The mask follows the profile (moonshine: padding only; Whisper: causal).
    final mask = _slice(call, r'writeDecoderMask\(', r'\);');
    expect(_count(mask, r'maxTokens:\s*maxTokens,'), 1);
    expect(_count(mask, r'len:\s*len,'), 1);
    expect(_count(mask, r'convention:\s*_profile\.decoderMaskConvention,'), 1);
    // The row of the token just written, read with the decoder's own sizes.
    final read = _slice(call, r'return _readDecoderRow\(', r'\);');
    expect(_count(read, r'outBufPtr\.value,'), 1);
    expect(_count(read, r'row:\s*len - 1,'), 1);
    expect(_count(read, r'maxTokens:\s*maxTokens,'), 1);
    expect(_count(read, r'vocabSize:\s*vocabSize,'), 1);
  });

  test('the decoder row is read with the buffer unlocked on every path', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final read = _slice(
      stt,
      r'Float32List _readDecoderRow\(',
      r'List<int> _ctcDecode\(',
    );
    final positions = {
      'lock': _at(read, r'\.lockTensorBuffer\('),
      'copy': _at(read, r'copied\s*=\s*logits\.sublist\('),
      'unlock on a failed copy': _at(
        read,
        r'_bindings\.unlockTensorBuffer\(buffer\);',
      ),
      'rethrow': _at(read, r'rethrow;'),
      'unlock, checked': _at(
        read,
        r'\.unlockTensorBuffer\(buffer\)\s*\.check\(',
      ),
      'return': _at(read, r'return copied;'),
    };
    for (final MapEntry(:key, :value) in positions.entries) {
      expect(value, isNonNegative, reason: '$key in $read');
    }
    // lock, copy, (on a failed copy: unlock, rethrow), unlock, return.
    final order = positions.values.toList();
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: '$positions');
    }
    expect(_count(read, r'\.unlockTensorBuffer\('), 2);
    expect(read, isNot(contains('if (')));
    // A read lock, checked; the copy is exactly row [row], no view and no
    // tail; every throwable is caught for the unlock, Errors (RangeError)
    // included.
    expect(
      _count(
        read,
        r'\.lockTensorBuffer\([^;]*kLiteRtTensorBufferLockModeRead[^;]*\)\s*\.check\(',
      ),
      1,
    );
    expect(
      _count(
        read,
        r'copied\s*=\s*logits\.sublist\(\s*row \* vocabSize,\s*\(row \+ 1\) \* vocabSize,?\s*\);',
      ),
      1,
    );
    expect(_count(read, r'\}\s*catch\s*\(_\)\s*\{'), 1);
  });
}
