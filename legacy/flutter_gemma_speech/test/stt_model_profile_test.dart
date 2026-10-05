import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show SttModelType;
import 'package:flutter_gemma_speech/src/model/stt_model_profile.dart';
import 'package:flutter_gemma_speech/src/tokenizer/stt_special_tokens.dart';
import 'package:flutter_gemma_speech/src/tokenizer/stt_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SttModelProfile.moonshine (byte-identical after the new fields)', () {
    test('unchanged existing fields', () {
      const p = SttModelProfile.moonshine();
      expect(p.inputType, SttInputType.rawPcm);
      expect(p.sampleRate, 16000);
      expect(p.windowSamples, 80000);
      expect(p.decodeType, SttDecodeType.seq2seq);
      expect(p.maxDecodeTokens, 64);
      expect(p.modes, {SttMode.batch});
    });

    test('new fields default to moonshine-safe values', () {
      const p = SttModelProfile.moonshine();
      expect(p.nMels, isNull);
      expect(p.nFft, isNull);
      expect(p.hopLength, isNull);
      expect(p.melFrames, isNull);
      expect(p.melAxisOrder, isNull);
      expect(p.melNormalization, SttMelNormalization.none);
      expect(p.melFilterAsset, isNull);
      expect(p.winLength, isNull);
      expect(p.preemphasis, isNull);
      expect(p.blankId, isNull);
      expect(p.decoderPromptTokens, [const SttTokenRef.id(1)]);
      expect(p.eosToken, const SttTokenRef.id(2));
      expect(p.suppressTokens, isNull);
      expect(p.tokenizerKind, SttTokenizerKind.sentencePiece);
      expect(p.decoderMaskConvention, SttDecoderMaskConvention.paddingOnly);
    });
  });

  group('SttModelProfile.whisper', () {
    test('carries the verified I/O contract values', () {
      final p = SttModelProfile.whisper();
      expect(p.inputType, SttInputType.logMel);
      expect(p.sampleRate, 16000);
      expect(p.windowSamples, 480000);
      expect(p.nMels, 80);
      expect(p.nFft, 400);
      expect(p.hopLength, 160);
      expect(p.melFrames, 3000);
      expect(p.melAxisOrder, SttMelAxisOrder.melFirst);
      expect(p.melNormalization, SttMelNormalization.whisper);
      expect(p.melFilterAsset, 'whisper_mel_80');
      expect(p.winLength, isNull);
      expect(p.preemphasis, isNull);
      expect(p.blankId, isNull);
      expect(p.decodeType, SttDecodeType.seq2seq);
      expect(p.maxDecodeTokens, 128);
      expect(p.modes, {SttMode.batch});
      expect(p.tokenizerKind, SttTokenizerKind.gpt2ByteLevelBpe);
      // Pin the Phase-0 spike finding: whisper's decoder is genuinely causal
      // (unlike moonshine's paddingOnly export). A silent flip to paddingOnly
      // would break decode masking with no other test signal — surfacing only
      // as soft on-device transcription drift. Do NOT relax without re-running
      // docs/superpowers/notes/whisper-stt-spike-findings.md.
      expect(p.decoderMaskConvention, SttDecoderMaskConvention.causal);
    });

    test('default English prompt, resolved by name (not hardcoded id)', () {
      final p = SttModelProfile.whisper();
      expect(p.decoderPromptTokens, [
        const SttTokenRef.name('<|startoftranscript|>'),
        const SttTokenRef.name('<|en|>'),
        const SttTokenRef.name('<|transcribe|>'),
        const SttTokenRef.name('<|notimestamps|>'),
      ]);
      expect(p.eosToken, const SttTokenRef.name('<|endoftext|>'));
    });

    test('suppression: everything above EOS, plus blank+EOS at step 0', () {
      final p = SttModelProfile.whisper();
      final resolver = SttSpecialTokenResolver({
        'model': {
          'vocab': {'Ġ': 5},
        },
        'added_tokens': [
          {'id': 100, 'content': '<|endoftext|>'},
        ],
      });
      final resolved = p.suppressTokens!.resolve(resolver);
      expect(resolved.suppressAboveId, 100);
      expect(resolved.suppressAtStepZeroIds, {5, 100});
    });
  });

  group('SttModelProfile.parakeet', () {
    test('carries the verified NeMo I/O contract values', () {
      const p = SttModelProfile.parakeet();
      expect(p.inputType, SttInputType.logMel);
      expect(p.sampleRate, 16000);
      expect(p.windowSamples, 80000);
      expect(p.nMels, 80);
      expect(p.nFft, 512);
      expect(p.hopLength, 160);
      expect(p.melFrames, 500);
      expect(p.winLength, 400);
      expect(p.preemphasis, 0.97);
      expect(p.melAxisOrder, SttMelAxisOrder.frameFirst);
      expect(p.melNormalization, SttMelNormalization.nemo);
      expect(p.melFilterAsset, 'nemo_mel_80');
      expect(p.decodeType, SttDecodeType.ctc);
      expect(p.modes, {SttMode.batch});
      expect(p.tokenizerKind, SttTokenizerKind.parakeetBpe);
      expect(p.blankId, 1024);
      // ctc reads no decoder mask, but pin the declared value so a refactor
      // that repurposes the field can't silently change parakeet's contract.
      expect(p.decoderMaskConvention, SttDecoderMaskConvention.paddingOnly);
    });

    test('no seed prompt, no eos, no suppression (ctc is single-pass)', () {
      const p = SttModelProfile.parakeet();
      expect(p.decoderPromptTokens, isEmpty);
      expect(p.eosToken, isNull);
      expect(p.suppressTokens, isNull);
    });
  });

  group('SttModelProfile.forType', () {
    test('moonshine', () {
      expect(
        SttModelProfile.forType(SttModelType.moonshine).inputType,
        SttInputType.rawPcm,
      );
    });

    test('whisper resolves to the log-mel profile (no longer throws)', () {
      final profile = SttModelProfile.forType(SttModelType.whisper);
      expect(profile.inputType, SttInputType.logMel);
      expect(profile.tokenizerKind, SttTokenizerKind.gpt2ByteLevelBpe);
    });

    test('parakeet resolves to the ctc log-mel profile (no longer throws)', () {
      final profile = SttModelProfile.forType(SttModelType.parakeet);
      expect(profile.decodeType, SttDecodeType.ctc);
      expect(profile.tokenizerKind, SttTokenizerKind.parakeetBpe);
    });
  });
}
