// The evidence writer hashes each file of a catalog build under the name
// core installs it under; these are held to the names core's own specs give.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/registry_evidence.dart';

void main() {
  test(
    'every STT build: model and namespaced tokenizer, as core names them',
    () {
      for (final model in LiteRtSpeechModels.stt) {
        for (final variant in model.variants.cast<SttVariant>()) {
          final spec = SttModelSpec(
            name: 'x',
            modelSource: ModelSource.network(variant.model.url),
            tokenizerSource: ModelSource.network(variant.tokenizer.url),
            sttModelType: variant.type,
          );
          expect(
            [for (final (name, _) in installedNamesOf(variant)) name],
            [for (final f in spec.files) f.filename],
            reason: variant.id,
          );
        }
      }
    },
  );

  test('every TTS bundle: each file under its type\'s namespace', () {
    for (final model in LiteRtSpeechModels.tts) {
      for (final variant in model.variants.cast<TtsVariant>()) {
        final spec = TtsModelSpec.fromManifest(
          name: variant.type.name,
          ttsModelType: variant.type,
          sourceFor: (name) => ModelSource.network('${variant.baseUrl}$name'),
        );
        expect(
          {for (final (name, _) in installedNamesOf(variant)) name},
          {for (final f in spec.files) f.filename},
          reason: variant.id,
        );
      }
    }
  });
}
