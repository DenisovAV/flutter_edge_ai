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
// omni/speech2text/asr_session.cc, class AudioInputSource) to Dart for
// flutter_edge_ai_speech.

/// Cuts a PCM stream into the overlapping model windows of streaming
/// speech-to-text.
///
/// Omni's `AudioInputSource` is a pipeline stage that pulls `AudioInput`
/// buffers and pushes one window per schedule; here it is a synchronous
/// object that returns every window a call makes ready. Resampling and the
/// channel/metadata checks of the original are out of scope: input is mono
/// at the model's sample rate.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// What kind of window an [AudioWindow] is.
enum AudioWindowKind {
  /// A full `samplesPerInterval` window.
  full,

  /// A progressive prefix of the stream emitted before the first full window
  /// (shorter than a window; only with warm start enabled).
  warmStart,

  /// The unpadded tail of a stream at a flush or the end of input (shorter
  /// than a window). It starts with the retained overlap of the previous full
  /// window, if any; the preprocessor pads it to the model window.
  remainder,
}

/// One window of audio for the recognizer.
final class AudioWindow {
  const AudioWindow(this.samples, this.kind);

  final Float32List samples;
  final AudioWindowKind kind;

  /// Omni's `IsLastOutputWarmStart()` for this window.
  bool get isWarmStart => kind == AudioWindowKind.warmStart;

  @override
  String toString() => 'AudioWindow(${kind.name}, ${samples.toList()})';
}

/// Omni's `AudioInputSource` windowing: windows of [samplesPerInterval]
/// samples, each starting `samplesPerInterval - overlapSamples` after the
/// previous one.
final class AudioWindower {
  /// [overlapSamples] outside `(0, samplesPerInterval)` means no overlap;
  /// warm start needs an overlap.
  AudioWindower({
    required int samplesPerInterval,
    required int overlapSamples,
    bool enableWarmStart = false,
  }) : samplesPerInterval = math.max(1, samplesPerInterval),
       overlapSamples =
           overlapSamples > 0 &&
               overlapSamples < math.max(1, samplesPerInterval)
           ? overlapSamples
           : 0,
       enableWarmStart =
           enableWarmStart &&
           overlapSamples > 0 &&
           overlapSamples < math.max(1, samplesPerInterval) {
    _nextWarmStartSamples = this.samplesPerInterval - this.overlapSamples;
  }

  /// The windowing of an Omni ASR session (`AsrSessionFactory::Create`):
  /// `samplesPerInterval = (int)(sampleRateHz * (inputMilliseconds / 1000.0))`
  /// and `overlapSamples = (int)(samplesPerInterval * overlapRatio)`, with
  /// [overlapRatio] a float as in Omni's session config (default 0.75).
  /// Omni enables warm start only when the model asks for it
  /// ([warmStartRequested]) and the session merges by timestamps
  /// ([timestampMerger]).
  factory AudioWindower.forSession({
    required int sampleRateHz,
    required int inputMilliseconds,
    double overlapRatio = 0.75,
    required bool timestampMerger,
    bool warmStartRequested = false,
  }) {
    final samplesPerInterval = (sampleRateHz * (inputMilliseconds / 1000.0))
        .truncate();
    final f32 = Float32List(2)
      ..[0] = samplesPerInterval.toDouble()
      ..[1] = overlapRatio;
    // `samples_per_interval * overlap_ratio()` is an int times a float: a
    // float product.
    f32[0] = f32[0] * f32[1];
    return AudioWindower(
      samplesPerInterval: samplesPerInterval,
      overlapSamples: f32[0].truncate(),
      enableWarmStart: warmStartRequested && timestampMerger,
    );
  }

  final int samplesPerInterval;
  final int overlapSamples;
  final bool enableWarmStart;

  int get _step => samplesPerInterval - overlapSamples;

  late int _nextWarmStartSamples;
  Float32List _buffer = Float32List(0);
  int _length = 0;
  // True when the buffer contains samples that have not yet been emitted in a
  // window (as opposed to only the retained `overlapSamples` tail of the
  // previous full window). Needed because when the buffer holds no more than
  // `overlapSamples`, its length alone cannot tell the unpushed samples of a
  // short stream from the already-pushed overlap tail.
  bool _hasUnpushedSamples = false;
  bool _hasPushedFullInterval = false;
  bool _isFinished = false;

  /// Whether [finish] was called (until [reset]).
  bool get isFinished => _isFinished;

  /// Appends [samples] and returns the windows that became ready: full
  /// windows, or, before the first full window, a warm-start prefix each time
  /// the stream grows by another step.
  ///
  /// Throws [StateError] after [finish] (Omni stops reading its input source
  /// at the end of input until a reset).
  List<AudioWindow> add(Float32List samples) {
    if (_isFinished) {
      throw StateError('AudioWindower.add after finish(); call reset() first.');
    }
    if (samples.isNotEmpty) {
      _hasUnpushedSamples = true;
      _append(samples);
    }
    final out = <AudioWindow>[];
    while (true) {
      if (_length >= samplesPerInterval) {
        out.add(_pushNextInterval());
      } else if (_shouldPushWarmStart()) {
        out.add(_pushWarmStart());
      } else {
        break;
      }
    }
    return out;
  }

  /// Omni's `Flush()` without the end of input: emits the full windows still
  /// buffered and then the unpadded remainder if it holds samples no window
  /// has carried yet. The stream can continue afterwards; the next window
  /// starts from the following sample and warm start may run again.
  List<AudioWindow> flush() {
    final out = <AudioWindow>[];
    while (_length >= samplesPerInterval) {
      out.add(_pushNextInterval());
    }
    if (_hasUnpushedSamples) {
      out.add(_pushRemainder());
    } else if (_isFinished) {
      _length = 0;
    }
    return out;
  }

  /// The end of input: emits the full windows still buffered and then the
  /// unpadded remainder if it holds samples no window has carried yet; the
  /// retained overlap of the last full window alone is never re-emitted.
  List<AudioWindow> finish() {
    _isFinished = true;
    final out = <AudioWindow>[];
    while (true) {
      if (_length >= samplesPerInterval) {
        out.add(_pushNextInterval());
        continue;
      }
      if (!_hasUnpushedSamples) {
        _length = 0;
        break;
      }
      out.add(_pushRemainder());
    }
    return out;
  }

  /// Forgets the stream, for a new one.
  void reset() {
    _length = 0;
    _hasUnpushedSamples = false;
    _hasPushedFullInterval = false;
    _nextWarmStartSamples = _step;
    _isFinished = false;
  }

  void _append(Float32List samples) {
    final needed = _length + samples.length;
    if (needed > _buffer.length) {
      final grown = Float32List(math.max(needed, _buffer.length * 2));
      grown.setRange(0, _length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_length, needed, samples);
    _length = needed;
  }

  bool _shouldPushWarmStart() =>
      enableWarmStart &&
      !_hasPushedFullInterval &&
      !_isFinished &&
      _hasUnpushedSamples &&
      _length >= _nextWarmStartSamples &&
      _length < samplesPerInterval;

  AudioWindow _pushWarmStart() {
    final step = _step;
    _nextWarmStartSamples = ((_length ~/ step) + 1) * step;
    _hasUnpushedSamples = false;
    return AudioWindow(
      Float32List.fromList(Float32List.sublistView(_buffer, 0, _length)),
      AudioWindowKind.warmStart,
    );
  }

  AudioWindow _pushNextInterval() {
    _hasPushedFullInterval = true;
    final step = _step;
    final output = Float32List.fromList(
      Float32List.sublistView(_buffer, 0, samplesPerInterval),
    );
    _buffer.setRange(0, _length - step, _buffer, step);
    _length -= step;
    _hasUnpushedSamples = _length > overlapSamples;
    return AudioWindow(output, AudioWindowKind.full);
  }

  AudioWindow _pushRemainder() {
    // Emit the remaining samples unpadded; the downstream preprocessor pads
    // to the model window after computing normalization statistics over real
    // audio.
    final output = Float32List.fromList(
      Float32List.sublistView(_buffer, 0, _length),
    );
    _length = 0;
    _hasUnpushedSamples = false;
    _hasPushedFullInterval = false;
    _nextWarmStartSamples = _step;
    return AudioWindow(output, AudioWindowKind.remainder);
  }
}
