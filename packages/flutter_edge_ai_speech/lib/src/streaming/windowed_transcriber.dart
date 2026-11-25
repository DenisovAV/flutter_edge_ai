// Windowed streaming speech-to-text for a model that reads a fixed window:
// LiteRT-LM Omni's pipeline (AudioInputSource windowing, short-chunk shift
// back, CTC with a decode range, TokenizerDetokenizer, TimestampTextMerger),
// driven from Dart over a function that runs one window. Pure Dart: the model
// run is injected, so every rule here is unit-tested without a model.
//
// `shiftShortChunkBack` is ported from LiteRT-LM v0.19.1
// omni/speech2text/utils.cc (ShiftShortChunkBackOverPreviousWindow),
// Copyright 2026 The ODML Authors, licensed under the Apache License, Version
// 2.0 (http://www.apache.org/licenses/LICENSE-2.0); modified: ported to Dart.
// The window preparation follows omni/speech2text/
// log_mel_spectrogram_processor.cc (the shift back only when a sixth of the
// window or more is missing, the decode range) except for the features of a
// padded window, which this package normalises over the whole window (see
// computeNemoLogMel).
library;

import 'dart:typed_data';

import 'audio_windower.dart';
import 'detokenizer.dart';
import 'text_merger.dart';
import 'timestamp_text_merger.dart';

/// Runs the model on one [window] of exactly the model's window length.
///
/// [validSamples] of it are audio, the rest zero padding; [startFraction] of
/// it, from the start, is audio already reported by an earlier window. The
/// runner returns the window's tokens with their frames, the end-of-chunk
/// sentinel last ([ctcWindowTokens]'s contract).
typedef WindowRunner =
    Future<List<DecodedToken>> Function(
      Float32List window, {
      required int validSamples,
      required double startFraction,
    });

/// What a step of the transcriber produced: [confirmed] text (already joined,
/// possibly empty), the current [unconfirmed] tail, and [confirmedUntil]:
/// a sample index, from the first sample given to the transcriber, before
/// which every word heard is in the confirmed text.
final class WindowedResult {
  const WindowedResult(
    this.confirmed,
    this.unconfirmed,
    this.confirmedUntil, {
    this.ranWindow = false,
  });

  final String confirmed;
  final String unconfirmed;
  final int confirmedUntil;

  /// Whether the step ran the model at all (adding a little audio often does
  /// not).
  final bool ranWindow;

  @override
  String toString() =>
      'WindowedResult(+"$confirmed", ~"$unconfirmed", until $confirmedUntil)';
}

/// Turns 16 kHz float audio, arriving in pieces, into confirmed and
/// unconfirmed text through overlapping windows.
final class WindowedTranscriber {
  WindowedTranscriber({
    required this.windowSamples,
    required double overlapRatio,
    required this._runWindow,
    required TokenIdsToUtf8 tokenIdsToUtf8,
  }) : _windower = AudioWindower(
         samplesPerInterval: windowSamples,
         overlapSamples: (windowSamples * _f32(overlapRatio)).truncate(),
         enableWarmStart: true,
       ),
       _detokenizer = TokenizerDetokenizer(tokenIdsToUtf8),
       _merger = TimestampTextMerger(overlapRatio: overlapRatio);

  /// The model's window, in samples.
  final int windowSamples;

  final WindowRunner _runWindow;
  final AudioWindower _windower;
  final TokenizerDetokenizer _detokenizer;
  final TimestampTextMerger _merger;

  /// The last full window, for shifting a short final chunk back over it.
  Float32List? _previousWindow;

  String _unconfirmed = '';

  /// Samples given to the transcriber before the current utterance (the
  /// last flush).
  int _origin = 0;

  /// Samples of the current utterance given to the windower.
  int _received = 0;

  /// Full windows run in the current utterance.
  int _fullWindows = 0;

  /// Encoder frames per window, from the last window's end-of-chunk time.
  int? _windowFrames;

  int _confirmedUntil = 0;

  bool _stopped = false;

  /// Stops at the next window boundary: windows not started yet are not run.
  void stop() => _stopped = true;

  /// Adds [samples] and runs every window they complete, in order.
  Future<WindowedResult> add(Float32List samples) {
    _received += samples.length;
    return _run(_windower.add(samples), flushMerger: false);
  }

  /// Ends an utterance without ending the stream: the remainder is run, the
  /// merger confirms everything, and the next audio starts a new utterance.
  Future<WindowedResult> flush() async {
    final result = await _run(_windower.flush(), flushMerger: true);
    _windower.reset();
    _merger.reset();
    _previousWindow = null;
    _origin += _received;
    _received = 0;
    _fullWindows = 0;
    _confirmedUntil = _origin;
    return result;
  }

  /// The end of the input: as [flush], and no audio may follow.
  Future<WindowedResult> finish() =>
      _run(_windower.finish(), flushMerger: true);

  Future<WindowedResult> _run(
    List<AudioWindow> windows, {
    required bool flushMerger,
  }) async {
    final confirmed = <String>[];
    var ran = false;
    for (final window in windows) {
      if (_stopped) break;
      final tokens = await _runPrepared(window);
      ran = true;
      if (window.kind == AudioWindowKind.full) _fullWindows++;
      final end = tokens.isEmpty ? null : tokens.last;
      if (end != null && end.isEndOfChunk && end.timestampMs != null) {
        _windowFrames ??= end.timestampMs;
      }
      final result = _merger.add(_detokenizer.detokenize(tokens));
      if (result.confirmed.isNotEmpty) confirmed.add(result.confirmed);
      _unconfirmed = result.unconfirmed;
    }
    if (flushMerger && !_stopped) {
      final MergeResult? result = _merger.flush();
      if (result != null) {
        if (result.confirmed.isNotEmpty) confirmed.add(result.confirmed);
        _unconfirmed = result.unconfirmed;
      }
      _confirmedUntil = _origin + _received;
    } else if (ran) {
      _advanceConfirmedUntil();
    }
    return WindowedResult(
      confirmed.join(' '),
      _unconfirmed,
      _confirmedUntil,
      ranWindow: ran,
    );
  }

  /// Every word before the newest full window's start is confirmed by the
  /// merger, and so is every word before the first one still unconfirmed;
  /// the bound is the smaller of the two, and never goes back. When the
  /// merger cannot place its unconfirmed words in time, the bound stays.
  void _advanceConfirmedUntil() {
    if (_fullWindows == 0) return;
    final step = _windower.samplesPerInterval - _windower.overlapSamples;
    var bound = (_fullWindows - 1) * step;
    final first = _merger.firstUnconfirmedTimestamp;
    if (first == -1) return;
    final frames = _windowFrames;
    if (first != null && frames != null && frames > 0) {
      // The merger rounds a window's start to whole frames, so a stored
      // timestamp can be up to a frame later than the word: go back a frame.
      final atSample = (first - 1) * windowSamples ~/ frames;
      if (atSample < bound) bound = atSample;
    }
    final absolute = _origin + (bound < 0 ? 0 : bound);
    if (absolute > _confirmedUntil) _confirmedUntil = absolute;
  }

  Future<List<DecodedToken>> _runPrepared(AudioWindow window) async {
    final samples = window.samples;
    switch (window.kind) {
      case AudioWindowKind.full:
        // The windower hands out a fresh list per window: keep it as is.
        _previousWindow = samples;
        return _runWindow(
          samples,
          validSamples: windowSamples,
          startFraction: 0,
        );
      case AudioWindowKind.warmStart:
        final tokens = await _runWindow(
          _padded(samples),
          validSamples: samples.length,
          startFraction: 0,
        );
        return _markWarmStart(tokens);
      case AudioWindowKind.remainder:
        final previous = _previousWindow;
        final missing = windowSamples - samples.length;
        if (previous != null &&
            previous.length == windowSamples &&
            missing > 0 &&
            missing * 6 >= windowSamples) {
          final shifted = shiftShortChunkBack(samples, previous);
          _previousWindow = shifted.window;
          return _runWindow(
            shifted.window,
            validSamples: windowSamples,
            startFraction: shifted.startFraction,
          );
        }
        return _runWindow(
          _padded(samples),
          validSamples: samples.length,
          startFraction: 0,
        );
    }
  }

  Float32List _padded(Float32List samples) {
    if (samples.length >= windowSamples) {
      return Float32List.sublistView(samples, 0, windowSamples);
    }
    return Float32List(windowSamples)..setAll(0, samples);
  }

  static List<DecodedToken> _markWarmStart(List<DecodedToken> tokens) => [
    for (final token in tokens)
      token.isEndOfChunk
          ? DecodedToken.endOfChunk(
              timestampMs: token.timestampMs,
              isWarmStart: true,
            )
          : token,
  ];
}

/// [remainder] (a short final chunk, which starts with the overlap the
/// windower keeps) moved back over [previous] to fill a whole window, and the
/// fraction of that window, from its start, that [previous] already covered.
/// LiteRT-LM Omni's `ShiftShortChunkBackOverPreviousWindow`: the overlap is
/// the longest suffix of [previous] that [remainder] starts with, so the
/// splice takes the samples just before it rather than repeating it.
({Float32List window, double startFraction}) shiftShortChunkBack(
  Float32List remainder,
  Float32List previous, {
  int minOverlapSamples = 1,
}) {
  final windowSamples = previous.length;
  final missing = windowSamples - remainder.length;
  if (missing <= 0) {
    throw ArgumentError.value(
      remainder.length,
      'remainder.length',
      'must be shorter than the window ($windowSamples)',
    );
  }
  var overlap = 0;
  final minOverlap = minOverlapSamples > 0 ? minOverlapSamples : 1;
  for (var candidate = remainder.length; candidate >= minOverlap; candidate--) {
    var equal = true;
    final from = windowSamples - candidate;
    for (var k = 0; k < candidate; k++) {
      if (previous[from + k] != remainder[k]) {
        equal = false;
        break;
      }
    }
    if (equal) {
      overlap = candidate;
      break;
    }
  }
  final window = Float32List(windowSamples)
    ..setRange(0, missing, previous, windowSamples - overlap - missing)
    ..setRange(missing, windowSamples, remainder);
  return (window: window, startFraction: missing / windowSamples);
}

double _f32(double value) => (Float32List(1)..[0] = value)[0];
