// The sentences core refuses an install with when it would write over a file
// an active model reads, one per kind, held to a golden file. The example
// app parses this same file (example/test/catalog_install_replacing_active_
// test.dart), so a wording change shows up there too, not only here.
//
// UPDATE_GOLDENS=1 flutter test test/catalog/active_file_refusal_golden_test.dart
// rewrites it (refused when CI is set).

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart'
    show activeFileRefusal;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_test/flutter_test.dart';

const goldenPath = 'test/catalog/active_file_refusals.golden.txt';

void main() {
  test('the refusal of each kind is the golden sentence', () {
    final sentences = [
      activeFileRefusal(
        "it's.litertlm",
        InferenceModelSpec(
          name: 'gemma',
          modelSource: ModelSource.network('https://example.com/m.litertlm'),
          modelType: ModelType.general,
          fileType: ModelFileType.litertlm,
        ),
      ),
      activeFileRefusal(
        'emb.tflite',
        EmbeddingModelSpec(
          name: 'emb',
          modelSource: ModelSource.network('https://example.com/emb.tflite'),
          tokenizerSource: ModelSource.network('https://example.com/t.model'),
        ),
      ),
      activeFileRefusal(
        'stt.tflite',
        SttModelSpec(
          name: 'stt',
          modelSource: ModelSource.network('https://example.com/stt.tflite'),
          tokenizerSource: ModelSource.network('https://example.com/t.json'),
          sttModelType: SttModelType.moonshine,
        ),
      ),
      activeFileRefusal(
        'a.tflite',
        TtsModelSpec(
          name: 'matcha',
          sources: [ModelSource.network('https://example.com/m/a.tflite')],
          ttsModelType: TtsModelType.matcha,
        ),
      ),
    ];
    final text = '${sentences.join('\n')}\n';
    final golden = File(goldenPath);
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      if (Platform.environment['CI'] != null) {
        fail('UPDATE_GOLDENS is refused on CI');
      }
      golden.writeAsStringSync(text);
    }
    expect(text, golden.readAsStringSync());
  });
}
