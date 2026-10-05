import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelType, TtsModelTypeManifest;
import 'package:flutter_gemma_speech/src/model/tts_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forType(matcha) gives the matcha CFM pipeline + file roles', () {
    final p = TtsModelProfile.forType(TtsModelType.matcha);
    expect(p.pipeline, TtsPipelineKind.matchaCfm);
    expect(p, isA<MatchaProfile>());
    final m = p as MatchaProfile;
    expect(m.textEncoderFile, 'matcha_textenc_fp16.tflite');
    expect(m.decoderFile, 'matcha_decoder_fp16.tflite');
    expect(m.vocoderFile, 'matcha_vocoder_fp16.tflite');
    expect(m.g2pFile, 'dp_g2p_matcha_fp16.tflite');
    expect(m.configFile, 'config.json');
    expect(m.dictFile, 'g2p_dict.txt.gz');
    expect(m.embeddingFile, 'emb.bin');
  });

  test('forType throws UnimplementedError for unwired families', () {
    for (final t in TtsModelType.values.where(
      (t) =>
          t != TtsModelType.matcha &&
          t != TtsModelType.qwen3 &&
          t != TtsModelType.inflect,
    )) {
      expect(
        () => TtsModelProfile.forType(t),
        throwsA(isA<UnimplementedError>()),
      );
    }
  });

  test(
    'matcha profile declares phonemeSymbols + dictionaryPlusNeural + en_us',
    () {
      const p = TtsModelProfile.matcha();
      expect(p.representation, TextRepresentation.phonemeSymbols);
      expect(p.g2p, G2pStrategy.dictionaryPlusNeural);
      expect(p.locale, 'en_us');
    },
  );

  test('forType(inflect) gives the VITS pipeline + file roles', () {
    final p = TtsModelProfile.forType(TtsModelType.inflect);
    expect(p.pipeline, TtsPipelineKind.inflectVits);
    expect(p, isA<InflectProfile>());
    final i = p as InflectProfile;
    expect(i.textEncoderFile, 'inflect_text_encoder_fp16.tflite');
    expect(i.decoderFile, 'inflect_decoder_fp16.tflite');
    expect(i.configFile, 'config.json');
    expect(i.dictFile, 'g2p_dict.txt.gz');
    // Reused Matcha G2P bundle (non-null role names — optionality is at the
    // artifact level, gated on containsKey in InflectTtsCore.load).
    expect(i.g2pFile, 'dp_g2p_matcha_fp16.tflite');
    expect(i.g2pMetaFile, 'g2p_meta.json');
    expect(i.representation, TextRepresentation.phonemeSymbols);
    expect(i.g2p, G2pStrategy.dictionaryPlusNeural);
    expect(i.locale, 'en_us');
  });

  test('InflectProfile file roles exactly cover the inflect install manifest', () {
    const p = InflectProfile();
    final roles = <String>{
      p.textEncoderFile,
      p.decoderFile,
      p.configFile,
      p.dictFile,
      p.g2pFile,
      p.g2pMetaFile,
    };
    // Bijection: every role resolves to a staged file AND every staged file has
    // a role. Drift between the profile and the install manifest would leave a
    // role unresolved (load fails) or a staged file unread — this catches it.
    expect(
      roles,
      TtsModelType.inflect.manifest.toSet(),
      reason: 'InflectProfile roles must match TtsModelType.inflect.manifest',
    );
  });
}
