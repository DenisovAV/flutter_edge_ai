// Prompt-embedding assembly for the Qwen3-TTS talker.
//
// `Qwen3Prompt.build` turns a text-token id sequence + a speaker x-vector +
// a language into:
//  - `prefill` — the fixed-length (~10-row) prompt embeddings fed to the
//    talker's `prefill_32` signature (role text + control/x-vector rows +
//    the first streamed text token),
//  - `trailing` — the rest of the text, one 1024-d embedding per decoded
//    audio frame, consumed during the per-frame decode loop,
//  - `ttsPad` — the fallback embedding used once `trailing` is exhausted.
//
// Ports `Qwen3TtsPipeline._build_prompt` verbatim from the recipe's
// `qwen3_tts_pipeline.py` (see `qwen3_tts_core.dart`'s file header for
// where it's vendored; plus its module-level token/language constants —
// `_CODEC_*`, `_TTS_*`, `LANGUAGE_IDS`), reading `ids` (already tokenized
// by the frontend, see `Qwen2BpeEncoder`) instead of re-tokenizing raw
// text.
//
// This file is pure Dart (`dart:typed_data` only) — no Flutter import — so
// it can be unit-tested without a device.

import 'dart:typed_data';

import 'qwen3_languages.dart' show languageIds;
import 'qwen3_tables.dart';

/// Talker hidden size — width of every embedding row this module handles.
const int _hidden = 1024;

// Talker codec-token vocabulary layout (ids >= 2048 are control tokens).
// Matches the recipe's codec-token constants block (`_CODEC_VOCAB` ..
// `_CODEC_NOTHINK` in `qwen3_tts_pipeline.py`).
const int _codecPad = 2148;
const int _codecBos = 2149;
const int _codecThink = 2154;
const int _codecNothink = 2155;
const int _codecThinkBos = 2156;
const int _codecThinkEos = 2157;

// Text-side special tokens (Qwen2 BPE vocabulary). Matches the recipe's
// `_TTS_BOS`/`_TTS_EOS`/`_TTS_PAD` in `qwen3_tts_pipeline.py`.
const int _ttsBos = 151672;
const int _ttsEos = 151673;
const int _ttsPad = 151671;

/// Result of [Qwen3Prompt.build]: the talker's fixed-length prefill
/// embeddings plus the per-frame streamed text conditioning consumed while
/// decoding audio frames.
class Qwen3PromptResult {
  const Qwen3PromptResult({
    required this.prefill,
    required this.promptLen,
    required this.trailing,
    required this.ttsPad,
  });

  /// Flattened prefill embeddings, row-major `[promptLen * 1024]`. Fed to
  /// the talker's `prefill_32` signature (right-padded to 32 rows by the
  /// caller — see `Qwen3TtsCore.runPrefill`, which ports `_run_prefill`).
  final Float32List prefill;

  /// Number of rows in [prefill] (`prefill.length == promptLen * 1024`).
  /// Fixed at `3 (role) + (codec_pre.length - 1) (body) + 1 (first_text)` —
  /// decoupled from text length (only `ids[:4]` feed the prefill; the rest
  /// of the text streams via [trailing]).
  final int promptLen;

  /// Per-frame streamed text-conditioning rows, each `[1024]`: the
  /// remaining text embeddings (`ids[4:-5]`) followed by the `tts_eos`
  /// embedding. Consumed one row per decoded audio frame; once exhausted,
  /// [ttsPad] is added instead (see the decode loop, `synthesize`, in
  /// `qwen3_tts_core.dart`).
  final List<Float32List> trailing;

  /// The `[1024]` TTS pad embedding, added once [trailing] is exhausted.
  final Float32List ttsPad;
}

/// Builds the Qwen3-TTS talker prompt.
///
/// Ports `Qwen3TtsPipeline._build_prompt` verbatim, given already-tokenized
/// [ids] (the frontend's chat-template encoding —
/// see `Qwen2BpeEncoder`), a `[1024]` speaker x-vector [speaker], and a
/// [language] (one of [languageIds]' keys, case-insensitive, or `'auto'`).
class Qwen3Prompt {
  Qwen3Prompt._();

  static Qwen3PromptResult build({
    required List<int> ids,
    required Float32List speaker,
    required String language,
    required Qwen3Tables tables,
  }) {
    if (speaker.length != _hidden) {
      throw ArgumentError.value(
        speaker.length,
        'speaker.length',
        'Qwen3Prompt.build: speaker must be [$_hidden]',
      );
    }
    if (ids.length < 4) {
      throw ArgumentError.value(
        ids.length,
        'ids.length',
        'Qwen3Prompt.build: ids must have at least 4 entries '
            '(role = ids[0:3], first text token = ids[3:4])',
      );
    }

    // qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final List<int> control;
    if (language == 'auto') {
      control = [_codecNothink, _codecThinkBos, _codecThinkEos];
    } else {
      final langId = languageIds[language.toLowerCase()];
      if (langId == null) {
        final sortedNames = (languageIds.keys.toList()..sort()).join(', ');
        throw ArgumentError.value(
          language,
          'language',
          'Qwen3Prompt.build: language must be "auto" or one of: '
              '$sortedNames',
        );
      }
      control = [_codecThink, _codecThinkBos, langId, _codecThinkEos];
    }

    // tts_bos, tts_eos, tts_pad = embedText([_TTS_BOS, _TTS_EOS, _TTS_PAD]).
    // qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final ttsSpecial = tables.embedText([_ttsBos, _ttsEos, _ttsPad]);
    final ttsBosRow = Float32List.sublistView(ttsSpecial, 0, _hidden);
    final ttsEosRow = Float32List.sublistView(ttsSpecial, _hidden, 2 * _hidden);
    final ttsPad = Float32List.sublistView(
      ttsSpecial,
      2 * _hidden,
      3 * _hidden,
    );

    // codec_pre = codec_emb[control] ++ [speaker] ++ codec_emb[[PAD, BOS]].
    // qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final codecPreLen = control.length + 1 + 2;
    final codecPre = List<Float32List>.generate(codecPreLen, (i) {
      if (i < control.length) return tables.codecEmbRow(control[i]);
      if (i == control.length) return speaker;
      if (i == control.length + 1) return tables.codecEmbRow(_codecPad);
      return tables.codecEmbRow(_codecBos);
    });

    // role = embedText(ids[0:3]). qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final role = tables.embedText(ids.sublist(0, 3));

    // pads = repeat(tts_pad, len(codec_pre) - 2);
    // body = concat([pads, tts_bos]) + codec_pre[:-1]  (element-wise add).
    // qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final bodyLen = codecPreLen - 1;
    final padsLen = codecPreLen - 2;
    final body = Float32List(bodyLen * _hidden);
    for (var i = 0; i < bodyLen; i++) {
      final base = i * _hidden;
      final addend = i < padsLen ? ttsPad : ttsBosRow;
      final codecRow = codecPre[i];
      for (var k = 0; k < _hidden; k++) {
        body[base + k] = addend[k] + codecRow[k];
      }
    }

    // first_text = embedText(ids[3:4]) + codec_pre[-1]. qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final firstTextEmbed = tables.embedText([ids[3]]);
    final firstText = Float32List(_hidden);
    final lastCodecPre = codecPre[codecPreLen - 1];
    for (var k = 0; k < _hidden; k++) {
      firstText[k] = firstTextEmbed[k] + lastCodecPre[k];
    }

    // prefill = concat(role, body, first_text). qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    final promptLen = 3 + bodyLen + 1;
    if (promptLen > 32) {
      // Defensive sanity check mirroring `Qwen3TtsPipeline._run_prefill`'s
      // `p > 32` guard — the talker's prefill signature is a fixed 32-row
      // buffer. This is NOT a text-length limit: only role +
      // control/x-vector rows enter the prefill (promptLen is fixed at 10
      // for a named language, 9 for 'auto'), so it never trips in practice.
      throw StateError(
        'Qwen3Prompt.build: prefill length $promptLen exceeds the talker '
        'prefill_32 signature (32)',
      );
    }
    final prefill = Float32List(promptLen * _hidden);
    prefill.setRange(0, 3 * _hidden, role);
    prefill.setRange(3 * _hidden, (3 + bodyLen) * _hidden, body);
    prefill.setRange((3 + bodyLen) * _hidden, promptLen * _hidden, firstText);

    // trailing = concat(embedText(ids[4:-5]), tts_eos). qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt.
    // Mirrors Python's permissive `ids[4:-5]` slicing (clamped to empty
    // rather than throwing) for very short inputs where `len(ids) - 5 < 4`.
    final trailingStop = ids.length - 5 < 4 ? 4 : ids.length - 5;
    final trailingTextIds = ids.sublist(4, trailingStop);
    final trailingText = tables.embedText(trailingTextIds);
    final trailing = <Float32List>[
      for (var i = 0; i < trailingTextIds.length; i++)
        Float32List.sublistView(trailingText, i * _hidden, (i + 1) * _hidden),
      Float32List.fromList(ttsEosRow),
    ];

    return Qwen3PromptResult(
      prefill: prefill,
      promptLen: promptLen,
      trailing: trailing,
      ttsPad: Float32List.fromList(ttsPad),
    );
  }
}
