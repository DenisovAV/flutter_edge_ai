// The endpoint state machine: Silero VAD probabilities, one per 512-sample
// frame at 16 kHz, in; speech start and end events out. Pure Dart, no I/O,
// so every rule is unit-tested without a model.
//
// It follows Silero's reference streaming iterator (`VADIterator` in
// silero-vad's `utils_vad.py`): speech turns on at `threshold`; once on, a
// frame below the negative threshold marks where silence began, a frame at or
// above `threshold` clears that mark, and a frame in between leaves it; the
// utterance ends when the silence since the mark reaches `minSilence`. Two
// rules are added for a live stream, where an event must be decided as the
// audio arrives: a start is reported only once the speech has lasted
// `minSpeech` (Silero's offline segmenter drops shorter segments after the
// fact, which a live caller cannot undo), and an utterance is cut at
// `maxUtterance`.
library;

import 'vad_event.dart';
import 'vad_options.dart';

/// Samples per Silero VAD frame at 16 kHz (32 ms).
const int vadFrameSamples = 512;

/// The only rate the bundled model runs at.
const int vadSampleRate = 16000;

/// [samples] at 16 kHz as a [Duration], exact to the microsecond.
Duration vadSamplesToDuration(int samples) =>
    Duration(microseconds: samples * 1000000 ~/ vadSampleRate);

int _durationToSamples(Duration d) =>
    (d.inMicroseconds * vadSampleRate / 1000000).round();

enum _Phase { idle, candidate, speaking }

/// Turns per-frame speech probabilities into [VadEvent]s under [VadOptions].
final class VadEndpointer {
  VadEndpointer(this.options)
    : _negative = options.effectiveNegativeThreshold,
      _minSpeech = _durationToSamples(options.minSpeech),
      _minSilence = _durationToSamples(options.minSilence),
      _pad = _durationToSamples(options.speechPad),
      _maxUtterance = _durationToSamples(options.maxUtterance) {
    options.validate();
  }

  final VadOptions options;
  final double _negative;
  final int _minSpeech;
  final int _minSilence;
  final int _pad;
  final int _maxUtterance;

  _Phase _phase = _Phase.idle;
  int _frames = 0;

  /// First sample of the first speech frame of the current utterance.
  int _onset = 0;

  /// Where the current silence began, while speech is on; null when the
  /// last frames were speech.
  int? _silenceFrom;

  /// The reported (padded) start of the utterance in progress.
  int _reportedStart = 0;

  /// Where the last utterance ended; the next one never starts before it, so
  /// no audio belongs to two utterances.
  int _lastEnd = 0;

  /// Samples of real audio seen so far: [samplesSeen] less the zeros that
  /// padded a final partial frame.
  int _received = 0;

  bool _finished = false;

  /// Whether an utterance has been reported as started and not yet ended.
  bool get inSpeech => _phase == _Phase.speaking;

  /// Samples seen so far, in whole frames.
  int get samplesSeen => _frames * vadFrameSamples;

  /// Feeds the probability of the next frame; returns the events it caused,
  /// in order (a start, an end, or a start then an end).
  ///
  /// [validSamples] is how much of the frame is real audio: less than 512
  /// only for a last frame padded with zeros, and then no event is placed
  /// past the real audio.
  List<VadEvent> add(double probability, {int validSamples = vadFrameSamples}) {
    if (_finished) throw StateError('VadEndpointer.add after finish');
    if (validSamples < 1 || validSamples > vadFrameSamples) {
      throw ArgumentError.value(
        validSamples,
        'validSamples',
        'must be in [1, $vadFrameSamples]',
      );
    }
    if (probability.isNaN || probability < 0 || probability > 1) {
      throw ArgumentError.value(
        probability,
        'probability',
        'a speech probability must be in [0, 1]',
      );
    }
    final frameStart = _frames * vadFrameSamples;
    _frames++;
    // Every duration below is measured to the end of the real audio in this
    // frame, so the zeros padding a last partial frame never count as speech
    // or silence.
    final frameEnd = frameStart + validSamples;
    _received = frameEnd;
    final events = <VadEvent>[];

    switch (_phase) {
      case _Phase.idle:
        if (probability >= options.threshold) {
          _phase = _Phase.candidate;
          _onset = frameStart;
          _silenceFrom = null;
          _confirmIfLongEnough(frameEnd, events);
        }
      case _Phase.candidate:
        _track(probability, frameStart);
        if (_silenceLongEnough(frameEnd)) {
          // Speech too short to report: forget it.
          _phase = _Phase.idle;
          _silenceFrom = null;
        } else {
          _confirmIfLongEnough(frameEnd, events);
        }
      case _Phase.speaking:
        _track(probability, frameStart);
        if (_silenceLongEnough(frameEnd)) {
          _end(_silenceFrom! + _pad, VadEndReason.silence, events);
        }
    }

    if (_phase == _Phase.speaking && frameEnd - _onset >= _maxUtterance) {
      _end(frameEnd, VadEndReason.maxUtterance, events);
    }
    return events;
  }

  /// Ends the stream; an utterance in progress ends at the last real sample
  /// at the latest. Returns the events this causes. No [add] may follow.
  List<VadEvent> finish() {
    if (_finished) return const [];
    _finished = true;
    final events = <VadEvent>[];
    if (_phase == _Phase.speaking) {
      final silence = _silenceFrom;
      _end(
        silence == null ? _received : silence + _pad,
        VadEndReason.inputEnded,
        events,
      );
    }
    _phase = _Phase.idle;
    return events;
  }

  void _track(double probability, int frameStart) {
    if (probability >= options.threshold) {
      _silenceFrom = null;
    } else if (probability < _negative) {
      _silenceFrom ??= frameStart;
    }
  }

  bool _silenceLongEnough(int frameEnd) {
    final silence = _silenceFrom;
    return silence != null && frameEnd - silence >= _minSilence;
  }

  void _confirmIfLongEnough(int frameEnd, List<VadEvent> events) {
    final speechEnd = _silenceFrom ?? frameEnd;
    if (speechEnd - _onset >= _minSpeech) {
      _phase = _Phase.speaking;
      final padded = _onset - _pad;
      _reportedStart = padded < _lastEnd ? _lastEnd : padded;
      events.add(VadSpeechStart(_reportedStart));
    }
  }

  void _end(int end, VadEndReason reason, List<VadEvent> events) {
    final capped = end > _received ? _received : end;
    events.add(VadSpeechEnd(_reportedStart, capped, reason));
    _lastEnd = capped;
    _phase = _Phase.idle;
    _silenceFrom = null;
  }
}
