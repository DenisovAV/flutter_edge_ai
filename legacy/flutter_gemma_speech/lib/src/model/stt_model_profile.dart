/// Per-model runtime descriptor for the generic LiteRT STT pipeline.
///
/// This is what makes the STT model SELECTABLE without per-model classes:
/// `LiteRtSpeechRecognizer`/`SttCore` are generic over [SttModelProfile] —
/// moonshine/whisper/parakeet are data (a profile + a catalog entry), not
/// separate recognizer classes. Mirrors how `InferenceModelSpec.modelType`
/// drives engine behavior via data rather than subclassing.
library;

import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show SttModelType;

import '../litert/log_mel_frontend.dart' show SttMelNormalization;
export '../litert/log_mel_frontend.dart' show SttMelNormalization;
import '../tokenizer/stt_special_tokens.dart';
import '../tokenizer/stt_tokenizer.dart' show SttTokenizerKind;

/// How audio is fed to the model's encoder.
enum SttInputType {
  /// Raw PCM samples, normalized to `[-1, 1]` — no mel frontend (moonshine).
  rawPcm,

  /// Log-mel spectrogram frames, computed by `log_mel_frontend.dart`
  /// (whisper, future parakeet).
  logMel,
}

/// How the model turns encoder output into token ids.
enum SttDecodeType {
  /// Autoregressive encoder→decoder loop (moonshine, whisper).
  seq2seq,

  /// Single-pass greedy CTC over encoder output (parakeet). Not implemented
  /// yet.
  ctc,
}

/// Batch (whole-utterance) vs streaming (incremental) transcription.
///
/// A property of the exported artifact, NOT the algorithm family: parakeet's
/// `_stateful` CTC export streams, its stateless export does not — same
/// [SttDecodeType], different [SttModelProfile.modes]. (Design spec §5.)
enum SttMode { batch, streaming }

/// Row-major layout of a log-mel frontend's output. `melFirst` = `[nMels,
/// melFrames]` (whisper); a future `frameFirst` = `[melFrames, nMels]`
/// (parakeet's contract, per stt-model-contract.md) is not implemented yet.
enum SttMelAxisOrder { melFirst, frameFirst }

/// Which convention `decode_args_2`'s `[1,1,maxDecodeTokens,maxDecodeTokens]`
/// mask follows. `paddingOnly` is moonshine's verified convention C
/// (docs/superpowers/notes/stt-transcript-recipe.md): `0.0 if j<len else
/// -1e9` for every query row, no causal restriction. `causal` additionally
/// restricts `j<=r`. Whisper's value is set from
/// docs/superpowers/notes/whisper-stt-spike-findings.md (Phase 0) — do not
/// change without re-running that spike.
enum SttDecoderMaskConvention { paddingOnly, causal }

/// Logit suppression applied before argmax at every decode step (whisper).
/// `null` on a profile means no suppression (moonshine, unchanged).
class SttSuppressionSpec {
  const SttSuppressionSpec({
    required this.suppressAbove,
    this.suppressAtStepZero = const [],
  });

  /// Every token id strictly greater than this resolves-to id is forced to
  /// `-inf` at EVERY decode step (whisper: `<|endoftext|>` — the timestamp
  /// block and all non-text specials sit contiguously above it).
  final SttTokenRef suppressAbove;

  /// Additionally forced to `-inf`, but ONLY at decode step 0 (OpenAI
  /// whisper's "suppress_blank": a lone leading space/EOS can't be the
  /// very first generated token).
  final List<SttTokenRef> suppressAtStepZero;

  ResolvedSuppression resolve(SttSpecialTokenResolver resolver) =>
      ResolvedSuppression(
        suppressAboveId: suppressAbove.resolve(resolver),
        suppressAtStepZeroIds: {
          for (final ref in suppressAtStepZero) ref.resolve(resolver),
        },
      );
}

/// Runtime descriptor for one STT model family — everything `SttCore` needs
/// to run a model that it does not auto-detect from the compiled model's
/// tensor layouts at load time.
class SttModelProfile {
  /// moonshine-tiny: raw PCM in, 5 s fixed window @ 16 kHz, seq2seq decode
  /// capped at 64 tokens. Values verified end-to-end in
  /// `docs/superpowers/notes/stt-transcript-recipe.md`. BOS=1/EOS=2 are
  /// given as fixed ids (not names) — moonshine needs no tokenizer.json
  /// resolution, matching the original verified recipe exactly.
  const SttModelProfile.moonshine()
    : languagePromptIndex = null,
      inputType = SttInputType.rawPcm,
      sampleRate = 16000,
      windowSamples = 80000,
      nMels = null,
      nFft = null,
      hopLength = null,
      melFrames = null,
      melAxisOrder = null,
      melNormalization = SttMelNormalization.none,
      melFilterAsset = null,
      winLength = null,
      preemphasis = null,
      decodeType = SttDecodeType.seq2seq,
      maxDecodeTokens = 64,
      modes = const {SttMode.batch},
      decoderPromptTokens = const [SttTokenRef.id(1)],
      eosToken = const SttTokenRef.id(2),
      suppressTokens = null,
      tokenizerKind = SttTokenizerKind.sentencePiece,
      decoderMaskConvention = SttDecoderMaskConvention.paddingOnly,
      blankId = null;

  /// whisper-tiny: log-mel in (30 s window), seq2seq decode capped at 128
  /// tokens, GPT-2 byte-level BPE vocab. Language-seeded prompt + suppression
  /// per docs/superpowers/specs/2026-07-31-whisper-stt-design.md (the prompt
  /// was English-only until the language became a parameter, #500).
  /// `decoderMaskConvention` is set from the Phase 0 spike finding
  /// (docs/superpowers/notes/whisper-stt-spike-findings.md) — `causal` is
  /// the verified winner (whisper's decoder is genuinely causal, unlike
  /// moonshine's export).
  ///
  /// The prompt's `<|en|>` is the DEFAULT output language, not a fixed one:
  /// `SttCore._promptFor` swaps that one id per transcription, driven by
  /// `SpeechRecognizer.language` / `transcribe(language:)`. `'en'` is kept as
  /// the default because it is what this profile shipped with before #500.
  const SttModelProfile.whisper()
    : languagePromptIndex = 1,
      inputType = SttInputType.logMel,
      sampleRate = 16000,
      windowSamples = 480000,
      nMels = 80,
      nFft = 400,
      hopLength = 160,
      melFrames = 3000,
      melAxisOrder = SttMelAxisOrder.melFirst,
      melNormalization = SttMelNormalization.whisper,
      melFilterAsset = 'whisper_mel_80',
      winLength = null,
      preemphasis = null,
      decodeType = SttDecodeType.seq2seq,
      maxDecodeTokens = 128,
      modes = const {SttMode.batch},
      decoderPromptTokens = const [
        SttTokenRef.name('<|startoftranscript|>'),
        // Slot [languagePromptIndex]. This is the DEFAULT only — the id here is
        // replaced per transcription by `SttCore._promptFor`, which is why the
        // language never has to be baked in and this constructor stays `const`.
        SttTokenRef.name('<|en|>'),
        SttTokenRef.name('<|transcribe|>'),
        SttTokenRef.name('<|notimestamps|>'),
      ],
      eosToken = const SttTokenRef.name('<|endoftext|>'),
      suppressTokens = const SttSuppressionSpec(
        suppressAbove: SttTokenRef.name('<|endoftext|>'),
        suppressAtStepZero: [
          SttTokenRef.name('Ġ'),
          SttTokenRef.name('<|endoftext|>'),
        ],
      ),
      tokenizerKind = SttTokenizerKind.gpt2ByteLevelBpe,
      decoderMaskConvention = SttDecoderMaskConvention.causal,
      blankId = null;

  /// parakeet-ctc-0.6b: NeMo log-mel in (5 s window, frame-first), single-
  /// pass greedy CTC decode (no decoder subgraph). Verified end-to-end in
  /// docs/superpowers/notes/parakeet-ctc-spike-findings.md (Python oracle +
  /// on-device Dart, byte-identical). Desktop-only (2.35 GB f32) -- the
  /// example catalog gates it accordingly (a documentation note, not a
  /// runtime check -- see stt_model.dart).
  const SttModelProfile.parakeet()
    : languagePromptIndex = null,
      inputType = SttInputType.logMel,
      sampleRate = 16000,
      windowSamples = 80000, // 5 s @ 16 kHz
      nMels = 80,
      nFft = 512,
      hopLength = 160,
      melFrames = 500,
      winLength = 400,
      preemphasis = 0.97,
      melAxisOrder = SttMelAxisOrder.frameFirst,
      melNormalization = SttMelNormalization.nemo,
      melFilterAsset = 'nemo_mel_80',
      decodeType = SttDecodeType.ctc,
      maxDecodeTokens = 0, // unused by ctc -- no per-step decode loop
      modes = const {SttMode.batch},
      decoderPromptTokens = const [], // ctc has no seed prompt
      eosToken = null, // ctc has no stop token -- single-pass, not a loop
      suppressTokens = null, // no logit suppression
      tokenizerKind = SttTokenizerKind.parakeetBpe,
      // unused by ctc (no per-step decode loop reads this).
      decoderMaskConvention = SttDecoderMaskConvention.paddingOnly,
      blankId = 1024;

  /// How audio is fed to the encoder.
  final SttInputType inputType;

  /// Expected input sample rate, Hz.
  final int sampleRate;

  /// Fixed input window, in samples (moonshine: 80000 = 5 s @ 16 kHz;
  /// whisper: 480000 = 30 s @ 16 kHz).
  final int windowSamples;

  /// Mel filterbank bin count (whisper: 80). `null` for `rawPcm` profiles.
  final int? nMels;

  /// STFT window size (whisper: 400). `null` for `rawPcm` profiles.
  final int? nFft;

  /// STFT hop length (whisper: 160). `null` for `rawPcm` profiles.
  final int? hopLength;

  /// Expected STFT frame count (whisper: 3000). `null` for `rawPcm` profiles.
  final int? melFrames;

  /// Log-mel output layout (whisper: melFirst). `null` for `rawPcm` profiles.
  final SttMelAxisOrder? melAxisOrder;

  /// Log-mel normalization scheme (whisper: whisper; moonshine: none/n-a).
  final SttMelNormalization melNormalization;

  /// Name of the bundled mel filterbank matrix to load (whisper:
  /// 'whisper_mel_80', see `mel_filter_assets.dart`). `null` for `rawPcm`.
  final String? melFilterAsset;

  /// STFT window length, when narrower than [nFft] (parakeet: 400, `nFft`
  /// 512 -- the Hann window is centered/zero-padded into the larger FFT
  /// buffer). `null` when `winLength == nFft` (whisper) or for `rawPcm`.
  final int? winLength;

  /// Pre-emphasis coefficient applied to raw PCM before framing (parakeet:
  /// 0.97, NeMo's default). `null` when the family applies none
  /// (moonshine, whisper).
  final double? preemphasis;

  /// How token ids are produced from encoder output.
  final SttDecodeType decodeType;

  /// Max autoregressive decode steps before forcing a stop (moonshine: 64;
  /// whisper: 128).
  final int maxDecodeTokens;

  /// Which transcription modes this model's exported artifact supports.
  /// moonshine/whisper: {batch}. Future parakeet stateful export: {batch,
  /// streaming}. Declarative capability data (design spec §5) — v1 has no
  /// consumer yet; the streaming gate lands with the streaming phase.
  final Set<SttMode> modes;

  /// Ordered decoder seed tokens (moonshine: single BOS id; whisper: the
  /// 4 transcription tokens, resolved by name at load time; the language slot
  /// carries the DEFAULT and is retargeted per call — see [languagePromptIndex]).
  final List<SttTokenRef> decoderPromptTokens;

  /// Stop-decoding token (moonshine: fixed EOS id 2; whisper: resolved
  /// `<|endoftext|>`). `null` for `ctc` profiles (parakeet) -- CTC is a
  /// single pass, not an autoregressive loop, so there is no stop token.
  final SttTokenRef? eosToken;

  /// Logit suppression applied every decode step before argmax. `null` =
  /// none (moonshine, unchanged).
  final SttSuppressionSpec? suppressTokens;

  /// Which `SttTokenizer` implementation decodes this family's output ids.
  final SttTokenizerKind tokenizerKind;

  /// Which `decode_args_2` mask formula `SttCore._decodeLoop` uses.
  final SttDecoderMaskConvention decoderMaskConvention;

  /// CTC blank class id (parakeet: 1024 = vocab_size, the last output
  /// class). `null` for `seq2seq` profiles (moonshine, whisper), which have
  /// no blank concept.
  final int? blankId;

  /// Index in [decoderPromptTokens] holding the language token, or `null` for a
  /// prompt with no language slot (moonshine, parakeet).
  ///
  /// This is what makes the language a per-CALL knob instead of a per-LOAD one.
  /// The seed prompt is copied fresh on every transcription anyway
  /// (`SttCore._decodeLoop`), so swapping one id in that copy costs a map
  /// lookup — no isolate respawn, no model reload, and no way for a cached
  /// recognizer to be stuck in the language it was built with.
  final int? languagePromptIndex;

  /// True if this model can drive a streaming (incremental) transcription.
  bool get supportsStreaming => modes.contains(SttMode.streaming);

  /// Resolve the runtime profile for [t].
  ///
  /// No `language` parameter, deliberately: the output language is a property
  /// of a TRANSCRIPTION, not of a loaded model (`SpeechRecognizer.language`
  /// and `transcribe(language:)`). Baking it in here is what made
  /// `getActiveStt(language:)` work only on the first call in a process.
  factory SttModelProfile.forType(SttModelType t) => switch (t) {
    SttModelType.moonshine => const SttModelProfile.moonshine(),
    SttModelType.whisper => const SttModelProfile.whisper(),
    SttModelType.parakeet => const SttModelProfile.parakeet(),
  };
}

/// Reject a Whisper language code whose SHAPE cannot be a language token,
/// before anything is loaded, and return it unchanged.
///
/// Whisper's codes are bare lowercase ISO-639-1/3 (`'en'`, `'de'`, `'yue'`) —
/// never `'de-DE'`, `'DE'`, `'german'` or `''`. Without this the string is
/// interpolated straight into `<|$language|>` and the only failure surface is
/// `SttSpecialTokenResolver`, which reports `token "<|de-DE|>" not found in
/// tokenizer.json` from inside the worker isolate — a message that reads like a
/// corrupt tokenizer bundle rather than a bad argument, after a full isolate
/// spawn and tokenizer parse.
///
/// Deliberately a SHAPE check, not an allow-list: hardcoding 99 codes is a
/// second copy of a list that lives in the shipped `tokenizer.json`, and
/// `qwen3_languages.dart`'s header records what those copies cost when they
/// drift. The exact per-checkpoint set is enforced at resolution time from the
/// tokenizer's own index, where it can never go stale.
///
/// It does NOT catch a well-formed code the checkpoint lacks (`'xx'`) — that is
/// the resolver's job, and it names the parameter when it fires.
String assertWhisperLanguage(String language) {
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
    throw ArgumentError.value(
      language,
      'language',
      "must be a bare lowercase Whisper language code like 'en' or 'de' "
          "(not a locale such as 'de-DE', not a name such as 'german')",
    );
  }
  return language;
}
