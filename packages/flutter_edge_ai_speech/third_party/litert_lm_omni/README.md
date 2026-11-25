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
| `test/streaming/levenshtein_align_test.dart` | `omni/speech2text/levenshtein_align_test.cc` |
| `test/streaming/levenshtein_text_merger_test.dart` | `omni/speech2text/levenshtein_text_merger_test.cc` |
| `test/streaming/timestamp_text_merger_test.dart` | `omni/speech2text/timestamp_text_merger_test.cc` |
| `test/streaming/detokenizer_test.dart` | `omni/speech2text/tokenizer_detokenizer_test.cc` |
| `test/streaming/audio_windower_test.dart` | the `AudioInputSource` cases of `omni/speech2text/asr_session_test.cc` |
