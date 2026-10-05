/// Per-model runtime descriptors for the on-device TTS pipelines.
///
/// This is what makes the TTS pipeline SELECTABLE without per-model synthesizer
/// classes: the worker/cores are generic over [TtsModelProfile] — a sealed
/// hierarchy with one variant per pipeline family ([MatchaProfile] /
/// [Qwen3Profile] / [InflectProfile]), each carrying ONLY the fields its
/// pipeline actually reads. Mirrors `SttModelProfile`. Unlike STT, the numeric
/// synthesis params (mel dims, CFM steps, sample rate, …) are NOT baked in
/// here — Matcha ships a `config.json` in its bundle and `TtsCore` reads them
/// from there at load time. A profile only carries the pipeline kind, the
/// text-representation/G2P declarations, and the ROLE of each bundle file
/// (which `.tflite` is the encoder/decoder/vocoder/G2P, plus the
/// config/dict/embedding filenames) for the pipelines that resolve files by
/// role.
library;

import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelType;

/// Which end-to-end synthesis pipeline a TTS model family uses.
enum TtsPipelineKind {
  /// Matcha-TTS: text-encoder (mu + logw duration predictor) → host-side
  /// Glow-TTS length regulator (256→512 frames) → N-step Euler CFM decoder →
  /// HiFi-GAN vocoder. Numeric params come from the bundle's config.json.
  matchaCfm,

  /// Qwen3-TTS: autoregressive codec-token LM (talker, prefill+decode over a
  /// threaded KV cache) → 15-step MTP residual-codebook inner loop →
  /// windowed codec decoder → 24 kHz PCM. Dispatched to `Qwen3TtsCore`
  /// (`flutter_gemma_speech/lib/src/qwen3/qwen3_tts_core.dart`) by the
  /// background worker — this pipeline kind never reaches the Matcha-only
  /// `TtsCore`/`TtsTextFrontend` path, which fail-loud on it instead of
  /// silently running Matcha behavior against a Qwen3 bundle.
  qwen3ArCodec,

  /// Inflect-Nano-v2 (VITS-style): text-encoder emits `m_p` + `logs_p` latents
  /// (last-dim 128) and `logw` log-durations (last-dim 1) → host-side length
  /// regulator (`durations = ceil(exp(logw))`, repeat each frame) + a
  /// fixed-seed Gaussian noise sample (`z_p = m_p + noise·exp(logs_p)·
  /// NOISE_SCALE`) → decoder emits 24 kHz waveform DIRECTLY (no separate
  /// vocoder). Phoneme ids in, PCM out. Dispatched to `InflectTtsCore`.
  inflectVits,
}

/// How text becomes the model's encoder input.
enum TextRepresentation { phonemeSymbols, subwordTokens, rawChars }

/// For phonemeSymbols models only: how graphemes become phonemes. Models with
/// no G2P stage at all (token models like Qwen3) express that as a null
/// [TtsModelProfile.g2p], not an enum value.
enum G2pStrategy { dictionary, dictionaryPlusNeural, neuralOnly }

/// Runtime descriptor for one TTS model family — sealed, one variant per
/// pipeline. The cores need this to know which `.tflite` to load for which
/// stage; they do not auto-detect roles from the compiled models' tensor
/// layouts. Consumers that need a variant's file-role fields narrow with a
/// type check (`is MatchaProfile` / pattern match) — the file roles live only
/// on the variants that use them, so "unused role" is unrepresentable.
sealed class TtsModelProfile {
  const TtsModelProfile();

  /// Matcha-TTS bundle profile ([MatchaProfile]): filenames match
  /// `TtsModelType.matcha.manifest`; there they get roles.
  const factory TtsModelProfile.matcha() = MatchaProfile;

  /// Qwen3-TTS profile ([Qwen3Profile]) — carries no file roles at all
  /// (`Qwen3TtsCore.load` hardcodes its own manifest basenames).
  const factory TtsModelProfile.qwen3() = Qwen3Profile;

  /// Inflect-Nano-v2 profile ([InflectProfile]) — encoder + decoder pair plus
  /// Matcha's reused G2P bundle; no vocoder/embedding roles.
  const factory TtsModelProfile.inflect() = InflectProfile;

  /// Which end-to-end synthesis pipeline this profile drives.
  TtsPipelineKind get pipeline;

  /// How text becomes the model's encoder input.
  TextRepresentation get representation;

  /// For phonemeSymbols models only: how graphemes become phonemes. Null for
  /// token models (no G2P stage exists in their pipeline).
  G2pStrategy? get g2p;

  /// Selects the `TtsTextNormalizer`; matcha/inflect/qwen3 → `'en_us'`.
  String get locale;

  /// Resolve the runtime profile for [t]. Only [TtsModelType.matcha],
  /// [TtsModelType.qwen3] and [TtsModelType.inflect] are wired;
  /// kokoro/supertonic are follow-ons and throw (fail-loud — never run text
  /// through the wrong pipeline).
  factory TtsModelProfile.forType(TtsModelType t) => switch (t) {
    TtsModelType.matcha => const MatchaProfile(),
    TtsModelType.qwen3 => const Qwen3Profile(),
    TtsModelType.inflect => const InflectProfile(),
    _ => throw UnimplementedError(
      'TTS profile for $t is a follow-on (only matcha/qwen3/inflect are wired)',
    ),
  };
}

/// Matcha-TTS bundle profile: filenames match `TtsModelType.matcha.manifest`;
/// here they get roles. Read by `TtsCore.load` (the 4 graphs + config +
/// g2p meta) and `MatchaTextFrontend.load` (config/dict/embedding).
final class MatchaProfile extends TtsModelProfile {
  const MatchaProfile();

  @override
  TtsPipelineKind get pipeline => TtsPipelineKind.matchaCfm;

  /// Text-encoder model file (mu + logw duration predictor).
  final String textEncoderFile = 'matcha_textenc_fp16.tflite';

  /// CFM decoder model file (N-step Euler ODE solver over mel frames).
  final String decoderFile = 'matcha_decoder_fp16.tflite';

  /// HiFi-GAN vocoder model file (mel → waveform).
  final String vocoderFile = 'matcha_vocoder_fp16.tflite';

  /// Grapheme-to-phoneme model file.
  final String g2pFile = 'dp_g2p_matcha_fp16.tflite';

  /// Neural G2P side-car: `char2idx`/`idx2ph` vocab + framing params
  /// (`char_repeats`/`start`/`end`/`MAXT`/`n_phonemes`) that `TtsCore` needs
  /// to run [g2pFile] and decode its output into IPA (`TtsCore.neuralG2p`).
  final String g2pMetaFile = 'g2p_meta.json';

  /// Bundle config file carrying the numeric synthesis params (read by
  /// `TtsCore`, not this profile).
  final String configFile = 'config.json';

  /// G2P dictionary file (gzipped).
  final String dictFile = 'g2p_dict.txt.gz';

  /// Speaker/style embedding file.
  final String embeddingFile = 'emb.bin';

  @override
  TextRepresentation get representation => TextRepresentation.phonemeSymbols;

  @override
  G2pStrategy get g2p => G2pStrategy.dictionaryPlusNeural;

  @override
  String get locale => 'en_us';
}

/// Qwen3-TTS profile: unlike [MatchaProfile], `Qwen3TtsCore.load` does NOT
/// resolve bundle files through profile roles — it hardcodes its own manifest
/// basenames (`talker_int4.tflite`, `mtp_fp32.tflite`,
/// `codec_decoder_fp32.tflite`, `tokenizer.json`, plus the 4 `Qwen3Tables`
/// npy/npz basenames; see `TtsModelTypeManifest.manifest` for
/// `TtsModelType.qwen3` in `flutter_gemma`'s `model_specs.dart`). So this
/// variant carries NO file-role fields at all — none of Matcha's roles (a
/// single text-encoder/decoder/vocoder trio) has a clean 1:1 equivalent in
/// the AR-codec pipeline's talker/MTP/codec-decoder split, and inventing one
/// would be misleading. Qwen3 does its own byte-level BPE tokenization
/// (`Qwen2BpeEncoder` over `tokenizer.json`), not G2P — hence [g2p] is null.
final class Qwen3Profile extends TtsModelProfile {
  const Qwen3Profile();

  @override
  TtsPipelineKind get pipeline => TtsPipelineKind.qwen3ArCodec;

  @override
  TextRepresentation get representation => TextRepresentation.subwordTokens;

  @override
  G2pStrategy? get g2p => null;

  @override
  String get locale => 'en_us';
}

/// Inflect-Nano-v2 profile: a text-encoder + decoder pair (no vocoder — the
/// decoder emits waveform, so there IS no vocoder role here). Its numeric
/// params (24 kHz, hop, NOISE_SCALE) are recipe constants in `InflectTtsCore`,
/// and the encoder takes token ids directly (no embedding gather), so there
/// is no embedding role either. Inflect uses the SAME espeak-style IPA and
/// the SAME 178-symbol table as Matcha (verified byte-identical), so it
/// REUSES Matcha's G2P bundle for the text→IPA frontend: [configFile] (the
/// symbol table), [dictFile] (word→IPA), [g2pFile]/[g2pMetaFile] (neural OOV
/// G2P — nullable/optional: an enc+dec-only bundle without dp_g2p still
/// loads, with dictionary-only G2P). `InflectTextFrontend` maps the IPA
/// string to raw token ids per-char (NO blank-interspersing, unlike Matcha).
final class InflectProfile extends TtsModelProfile {
  const InflectProfile();

  @override
  TtsPipelineKind get pipeline => TtsPipelineKind.inflectVits;

  /// VITS text-encoder model file (`m_p`/`logs_p`/`logw` heads).
  final String textEncoderFile = 'inflect_text_encoder_fp16.tflite';

  /// VITS decoder model file (latents → 24 kHz waveform directly).
  final String decoderFile = 'inflect_decoder_fp16.tflite';

  /// Neural OOV G2P model file (Matcha's shared dp_g2p). Always DECLARED
  /// (non-null, like [MatchaProfile.g2pFile]) — the optionality is at the
  /// ARTIFACT level, not the name: `InflectTtsCore.load` skips the neural G2P
  /// when the bundle at hand doesn't stage this file (gated on
  /// `artifactPaths.containsKey`, never on a null filename).
  final String g2pFile = 'dp_g2p_matcha_fp16.tflite';

  /// Side-car meta for [g2pFile] (vocab + framing params); same artifact-level
  /// optionality as [g2pFile].
  final String g2pMetaFile = 'g2p_meta.json';

  /// Symbol-table config file (Matcha's `config.json`, reused).
  final String configFile = 'config.json';

  /// G2P dictionary file (gzipped; Matcha's `g2p_dict.txt.gz`, reused).
  final String dictFile = 'g2p_dict.txt.gz';

  @override
  TextRepresentation get representation => TextRepresentation.phonemeSymbols;

  @override
  G2pStrategy get g2p => G2pStrategy.dictionaryPlusNeural;

  @override
  String get locale => 'en_us';
}
