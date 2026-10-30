// The two places speech compiles a LiteRT graph (SttCore.load and
// loadLiteRtGraph, which every TTS core goes through) need a real native
// library to run, so a VM test cannot load a model through them. This holds
// their source to the rules that the GPU-options tests rely on (#747): every
// set of compilation options gets its accelerator through
// configureSpeechAccelerator (which adds the fp32 GPU options for
// speech-to-text only), never through
// a direct setOptionsHardwareAccelerators call, every compile failure is
// checked through checkCompiledModelStatus, and the seq2seq decoder picks each
// token through greedyDecodeStep and acceptDecodedToken (whole-row NaN check).
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
      // Keyed with '/' on every host, so the paths below match on Windows too.
      if (file.path.endsWith('.dart'))
        file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
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

  test('every compile status goes through checkCompiledModelStatus', () {
    final checked = <String>[];
    for (final MapEntry(:key, :value) in sources.entries) {
      final compiles = _count(value, r'\.createCompiledModel\(');
      if (compiles == 0) continue;
      checked.add(key);
      expect(
        _count(value, r'checkCompiledModelStatus\(\s*status,'),
        compiles,
        reason: '$key compiles a graph without checkCompiledModelStatus',
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

  test('the seq2seq decoder picks tokens through greedyDecodeStep', () {
    final stt = sources['lib/src/litert/stt_core.dart']!;
    final loop = stt.substring(
      stt.indexOf('List<int> _decodeLoop('),
      stt.indexOf('List<int> _ctcDecode('),
    );
    expect(_count(loop, r'greedyDecodeStep\('), 1);
    expect(loop, isNot(contains('argmax(')));
    // Its pick is the token, through the check that throws on a NaN row.
    expect(_count(loop, r'acceptDecodedToken\(\s*next,'), 1);
  });
}
