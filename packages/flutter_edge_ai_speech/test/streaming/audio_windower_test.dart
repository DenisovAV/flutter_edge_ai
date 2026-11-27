// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified: ported from C++ (LiteRT-LM v0.19.1,
// omni/speech2text/asr_session_test.cc, the AudioInputSource cases) to Dart
// for flutter_edge_ai_speech.
//
// The C++ cases drive a whole fake session: AudioInputSource -> a fake
// preprocessor (features = the samples) -> a fake recognizer (one token per
// sample, id = the sample value, timestamp 100; a warm-start window adds an
// end-of-chunk sentinel flagged warm start) -> a fake detokenizer (token N ->
// word "w_N") -> LevenshteinTextMerger. `_FakeAsrSession` below rebuilds that
// chain over AudioWindower and the ported LevenshteinTextMerger, with the
// same fakes. The upstream expectations are kept as they are.
//
// MultiStagedSession is not among the ported sources. Its behaviour is
// assumed as follows (reconstructed from these tests' expectations, not from
// its source): ProcessNext() returns the merger's output for the next window,
// NotFound when no window is ready and OutOfRange once the end of input has
// been consumed; Flush() flushes every stage (windower, then merger) and
// reports the confirmed texts produced on the way joined by a space, with the
// last output's unconfirmed text; the end of input (ProcessAsync) flushes the
// merger after the last window.
//
// Not ported:
// - AllDefaultModelsAreRegistered, RejectsUnknownModelOnCreate,
//   DynamicRegisterAndUnregisterModel: the Omni model registry, not the
//   AudioInputSource.
// - AudioInputSourceValidatesMetadataAndInputTypes: AudioInputMetadata and
//   TextInput validation of the C++ input-source variant; AudioWindower takes
//   only mono PCM samples at the model rate, so there is no metadata or other
//   input type to refuse.
// - AudioInputSourceResamplesFromAudioInputMetadata: resampling is out of
//   scope for the port (input is 16 kHz).

import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/src/streaming/audio_windower.dart';
import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/levenshtein_text_merger.dart';
import 'package:flutter_edge_ai_speech/src/streaming/text_merger.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _pcm(List<double> samples) => Float32List.fromList(samples);

// FakeAudioPreprocessor + FakeSpeechRecognizer + FakeDetokenizer.
List<DetokenizedWord> _fakeWords(AudioWindow window) {
  final tokens = <DecodedToken>[
    for (final value in window.samples)
      DecodedToken(value.toInt(), timestampMs: 100),
    if (window.isWarmStart) const DecodedToken.endOfChunk(isWarmStart: true),
  ];
  return [
    for (final tok in tokens)
      tok.isEndOfChunk
          ? DetokenizedWord.endOfChunk(
              timestampMs: tok.timestampMs,
              isWarmStart: tok.isWarmStart,
            )
          : DetokenizedWord('w_${tok.tokenId}', timestampMs: tok.timestampMs),
  ];
}

final class _FakeAsrSession {
  _FakeAsrSession(this.windower);

  final AudioWindower windower;
  final LevenshteinTextMerger merger = LevenshteinTextMerger();
  final List<AudioWindow> _pending = [];
  bool _endOfInput = false;

  void pushInput(List<double> samples) =>
      _pending.addAll(windower.add(_pcm(samples)));

  void finish() {
    _endOfInput = true;
    _pending.addAll(windower.finish());
  }

  /// The next merger output, or null where the C++ session returns NotFound
  /// (no window ready) or OutOfRange (end of input consumed).
  MergeResult? processNext() {
    if (_pending.isEmpty) return null;
    return merger.add(_fakeWords(_pending.removeAt(0)));
  }

  /// Every output until the end of input, as ProcessAsync delivers them.
  List<MergeResult> processAll() {
    final outputs = <MergeResult>[];
    while (_pending.isNotEmpty) {
      outputs.add(merger.add(_fakeWords(_pending.removeAt(0))));
    }
    if (_endOfInput) {
      final flushed = merger.flush();
      if (flushed != null) outputs.add(flushed);
    }
    return outputs;
  }

  MergeResult flush() {
    _pending.addAll(windower.flush());
    final outputs = <MergeResult>[];
    while (_pending.isNotEmpty) {
      outputs.add(merger.add(_fakeWords(_pending.removeAt(0))));
    }
    final flushed = merger.flush();
    if (flushed != null) outputs.add(flushed);
    return MergeResult(
      outputs.map((o) => o.confirmed).where((t) => t.isNotEmpty).join(' '),
      outputs.isEmpty ? '' : outputs.last.unconfirmed,
    );
  }

  void reset() {
    windower.reset();
    merger.reset();
    _pending.clear();
    _endOfInput = false;
  }
}

void main() {
  // The windows the upstream comments of
  // OverlapAndUnpaddedRemainderOnFlushAndReset describe, checked on the
  // windower itself (not an upstream case).
  test('windows described by OverlapAndUnpaddedRemainderOnFlushAndReset', () {
    final windower = AudioWindower(samplesPerInterval: 3, overlapSamples: 1);

    final first = windower.add(_pcm([1, 2, 3, 4]));
    expect(first, hasLength(1));
    expect(first.single.kind, AudioWindowKind.full);
    expect(first.single.samples, [1, 2, 3]);

    final flushed = windower.flush();
    expect(flushed, hasLength(1));
    expect(flushed.single.kind, AudioWindowKind.remainder);
    expect(flushed.single.samples, [3, 4]);
  });

  group('AsrSessionTest', () {
    test('OverlapAndUnpaddedRemainderOnFlushAndReset', () {
      // Interval = 3 samples, overlap = 1 sample (step = 2 samples).
      final session = _FakeAsrSession(
        AudioWindower(samplesPerInterval: 3, overlapSamples: 1),
      );

      session.pushInput([1, 2, 3, 4]);

      // First interval consumes [1, 2, 3], retaining overlap [3] + remaining
      // [4].
      final out1 = session.processNext();
      expect(out1?.unconfirmed, 'w_1 w_2 w_3');

      // Flush() emits the remaining [3, 4] unpadded (the preprocessor is
      // responsible for padding to the model window) and flushes the merger,
      // without marking the stream finished if EndOfInput was not sent.
      final flushed = session.flush();
      expect(flushed.confirmed, 'w_1 w_2 w_3 w_4');

      // Pushing more audio after Flush() continues to work without Reset().
      session.pushInput([5, 6, 7]);
      final out2 = session.processNext();
      expect(out2?.unconfirmed, 'w_5 w_6 w_7');

      // Reset() allows a new stream on the same session even after Finish().
      session.finish();
      session.flush();
      session.reset();
      session.pushInput([7, 8, 9]);
      final flushed2 = session.flush();
      expect(flushed2.confirmed, 'w_7 w_8 w_9');
    });

    test('PartialFragmentsAndCoalescedInputsWaitUntilIntervalOrEndOfInput', () {
      final session = _FakeAsrSession(
        AudioWindower(samplesPerInterval: 3, overlapSamples: 0),
      );

      // Partial chunk (< 3 samples) before EndOfInput returns NotFoundError
      // rather than prematurely padding or returning OutOfRangeError.
      session.pushInput([1]);
      expect(session.processNext(), isNull);

      // Multiple consecutive chunks pushed before ProcessNext() are coalesced
      // up to samples_per_interval_.
      session.pushInput([2]);
      session.pushInput([3, 4]);
      session.pushInput([5]);
      final out1 = session.processNext();
      expect(out1?.unconfirmed, 'w_1 w_2 w_3');

      // Remaining [4.0f] + [5.0f] (< 3 samples) still waits for more input
      // until Finish().
      expect(session.processNext(), isNull);

      session.finish();
      final out2 = session.processNext();
      expect(out2?.unconfirmed, 'w_4 w_5');

      expect(session.processNext(), isNull);
    });

    test('ProcessAsyncWithEndOfInputAndRemainderPadding', () {
      final session = _FakeAsrSession(
        AudioWindower(samplesPerInterval: 3, overlapSamples: 0),
      );

      // Push 2 samples (< interval=3) followed by EndOfInput. The source
      // emits the unpadded remainder [5, 6], and EOS flushes the text merger.
      session.pushInput([5, 6]);
      session.finish();

      final outputs = session.processAll();
      expect(outputs, isNotEmpty);
      expect(outputs.last.confirmed, 'w_5 w_6');
    });

    test(
      'FinishWithoutNewSamplesAfterFullIntervalDoesNotEmitOverlapRemainder',
      () {
        // Interval = 3 samples, overlap = 1 sample.
        final session = _FakeAsrSession(
          AudioWindower(samplesPerInterval: 3, overlapSamples: 1),
        );

        // Push exactly one full interval (3 samples), then Finish() with no
        // new samples. The retained overlap sample [3] must not be emitted as
        // a phantom remainder chunk at EOS.
        session.pushInput([1, 2, 3]);
        final out1 = session.processNext();
        expect(out1?.unconfirmed, 'w_1 w_2 w_3');

        session.finish();
        expect(session.processNext(), isNull);
        final eosFlush = session.flush();
        expect(eosFlush.confirmed, 'w_1 w_2 w_3');
        expect(eosFlush.unconfirmed, '');
      },
    );

    test('WarmStartEmitsProgressivePrefixesBeforeFullInterval', () {
      // 8000 Hz, 1 ms per interval -> 8 samples per interval; overlap ratio
      // 0.75 -> overlap = 6, step = 2 samples; timestamp merger, warm start
      // requested.
      final session = _FakeAsrSession(
        AudioWindower.forSession(
          sampleRateHz: 8000,
          inputMilliseconds: 1,
          overlapRatio: 0.75,
          timestampMerger: true,
          warmStartRequested: true,
        ),
      );
      expect(session.windower.samplesPerInterval, 8);
      expect(session.windower.overlapSamples, 6);

      // 1 sample (< step of 2) -> not enough for first warm-start prefix yet.
      session.pushInput([1]);
      expect(session.processNext(), isNull);

      // 2 samples -> first warm-start prefix [1, 2]
      session.pushInput([2]);
      final ws1 = session.processNext();
      expect(ws1?.unconfirmed, 'w_1 w_2');

      // 2 more samples (total 4) -> second warm-start prefix [1, 2, 3, 4]
      session.pushInput([3, 4]);
      final ws2 = session.processNext();
      expect(ws2, isNotNull);

      // If Finish() is called right after a warm-start emission with no new
      // samples, no redundant remainder chunk is emitted.
      session.finish();
      expect(session.processNext(), isNull);

      // Resetting restores the initial warm-start step threshold (2 samples).
      session.reset();
      session.pushInput([5]);
      expect(session.processNext(), isNull);
      session.pushInput([6]);
      final wsReset = session.processNext();
      expect(wsReset?.unconfirmed, 'w_5 w_6');
    });

    test('WarmStartIsDisabledForLevenshteinTextMerger', () {
      final session = _FakeAsrSession(
        AudioWindower.forSession(
          sampleRateHz: 8000,
          inputMilliseconds: 1,
          overlapRatio: 0.75,
          timestampMerger: false,
          warmStartRequested: true,
        ),
      );

      // With Levenshtein merger, warm-start is gated off even when the
      // factory opts in via ShouldEnableWarmStart().
      session.pushInput([1, 2]);
      expect(session.processNext(), isNull);

      session.finish();
      final out = session.processNext();
      expect(out?.unconfirmed, 'w_1 w_2');
    });
  });
}
