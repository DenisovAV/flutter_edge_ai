# LiteRT-LM Omni (ported files)

Parts of the streaming speech-to-text pipeline of LiteRT-LM Omni, ported from
C++ to Dart. Upstream: https://github.com/google-ai-edge/LiteRT-LM, tag
`v0.19.1`. Licensed under the Apache License, Version 2.0 (`LICENSE` in this
directory). Each ported file keeps the upstream copyright notice and says what
was modified.

| Dart file | Upstream source |
|-----------|-----------------|
| `lib/src/streaming/text_utils.dart` | `omni/base/text_utils.{h,cc}` |
| `lib/src/streaming/levenshtein_align.dart` | `omni/speech2text/levenshtein_align.{h,cc}` |
| `lib/src/streaming/text_merger.dart` | `omni/speech2text/text_merger.h` |
| `lib/src/streaming/levenshtein_text_merger.dart` | `omni/speech2text/levenshtein_text_merger.{h,cc}` |
| `lib/src/streaming/timestamp_text_merger.dart` | `omni/speech2text/timestamp_text_merger.{h,cc}` |
| `lib/src/streaming/detokenizer.dart` | `omni/speech2text/detokenizer.h`, `omni/speech2text/tokenizer_detokenizer.{h,cc}` |
| `lib/src/streaming/audio_windower.dart` | `omni/speech2text/asr_session.cc` (class `AudioInputSource`) |
| `lib/src/streaming/ctc_window_decoder.dart` | `omni/speech2text/ctc_decoder.{h,cc}` (`CtcDecoder::Decode`) |
| `lib/src/streaming/windowed_transcriber.dart` | `omni/speech2text/utils.cc` (`ShiftShortChunkBackOverPreviousWindow`); window preparation after `omni/speech2text/log_mel_spectrogram_processor.cc` |
| `test/streaming/ctc_window_decoder_test.dart` | `omni/speech2text/ctc_decoder_test.cc` |
| `test/streaming/levenshtein_align_test.dart` | `omni/speech2text/levenshtein_align_test.cc` |
| `test/streaming/levenshtein_text_merger_test.dart` | `omni/speech2text/levenshtein_text_merger_test.cc` |
| `test/streaming/timestamp_text_merger_test.dart` | `omni/speech2text/timestamp_text_merger_test.cc` |
| `test/streaming/detokenizer_test.dart` | `omni/speech2text/tokenizer_detokenizer_test.cc` |
| `test/streaming/audio_windower_test.dart` | the `AudioInputSource` cases of `omni/speech2text/asr_session_test.cc` |

Changes to the merge, each marked "Deviation from Omni" where it is made and
measured on LibriSpeech (numbers in the package README): words confirmed early
stay in the overlap alignment; a current-only word aligned inside text already
confirmed is dropped; the tail of a word cut by the window start is dropped up
to `tol.matchLate` frames into the window, not only `tol.substitution`.

Not ported: Omni's skip of silent windows, its trimming of trailing silence,
and `MaybeRetryWithCenteredFeatures` (a window whose first token comes late is
run again on features framed differently). Small differences:
`shiftShortChunkBack` accepts an overlap of 1 sample where Omni requires
`hop_length` (160), which real audio, whose kept overlap is thousands of
samples, never reaches; the window's start fraction is a double, not a float.
