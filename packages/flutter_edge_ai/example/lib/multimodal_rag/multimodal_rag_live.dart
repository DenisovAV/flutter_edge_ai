// Live: audio arrives as a stream of 16 kHz mono PCM16 chunks (from the
// microphone, or a recording played as if it were) and is cut into windows,
// each an utterance: a window ends at the first pause once it holds enough
// speech, and at most [kLiveMaxWindow] in (cut at its quietest moment), so a
// question rarely straddles two windows. Pure Dart; unit-tested in
// test/multimodal_rag_logic_test.dart.

import 'dart:math' as math;
import 'dart:typed_data';

import 'multimodal_rag_audio.dart';

/// A window ends at the first pause after this much audio …
const kLiveMinWindow = Duration(milliseconds: 1800);

/// … and is cut here when no pause came.
const kLiveMaxWindow = Duration(seconds: 6);

/// A pause: this long below [kSilenceLevel].
const kLivePause = Duration(milliseconds: 280);

/// The level (RMS, 0 to 1) below which a 20 ms frame is silence.
const kSilenceLevel = 0.006;

/// The shortest tail worth hearing when the audio ends.
const kLiveMinTail = Duration(milliseconds: 800);

const _frameBytes = 640; // 20 ms

/// Cuts a stream of PCM chunks into utterance windows.
final class MeetingWindower {
  final _buffer = BytesBuilder(copy: false);
  final _carry = BytesBuilder(copy: false);
  Duration _start = Duration.zero;
  Duration _silence = Duration.zero;
  bool _speech = false;

  /// How much audio has come in.
  Duration heard = Duration.zero;

  /// Adds [chunk]; returns the windows it completed, with where each starts.
  List<({Duration start, Uint8List pcm})> add(Uint8List chunk) {
    heard += pcmDuration(chunk);
    _carry.add(chunk);
    final bytes = _carry.takeBytes();
    final whole = bytes.length - bytes.length % _frameBytes;
    if (whole < bytes.length) _carry.add(Uint8List.sublistView(bytes, whole));
    final windows = <({Duration start, Uint8List pcm})>[];
    for (var i = 0; i < whole; i += _frameBytes) {
      final frame = Uint8List.sublistView(bytes, i, i + _frameBytes);
      final silent = pcmLevel(frame) / 5 < kSilenceLevel;
      if (silent && !_speech) {
        // Silence before any speech: not part of the window.
        _start += pcmDuration(frame);
        continue;
      }
      _buffer.add(frame);
      _speech = true;
      _silence = silent ? _silence + pcmDuration(frame) : Duration.zero;
      final length = Duration(
        microseconds:
            _buffer.length *
            Duration.microsecondsPerSecond ~/
            kPcmBytesPerSecond,
      );
      if (length >= kLiveMinWindow && _silence >= kLivePause) {
        windows.add(_emit(_buffer.takeBytes()));
      } else if (length >= kLiveMaxWindow) {
        final pieces = splitForSpeechWindow(
          _buffer.takeBytes(),
          window: kLiveMaxWindow,
        );
        windows.add(_emit(pieces.first));
        for (final rest in pieces.skip(1)) {
          _buffer.add(rest);
        }
      }
    }
    return windows;
  }

  /// What is left when the audio ends, if it is long enough to hear.
  ({Duration start, Uint8List pcm})? flush() {
    final rest = _buffer.takeBytes();
    if (pcmDuration(rest) < kLiveMinTail) return null;
    return _emit(rest);
  }

  ({Duration start, Uint8List pcm}) _emit(Uint8List pcm) {
    final start = _start;
    _start += pcmDuration(pcm);
    _speech = false;
    _silence = Duration.zero;
    return (start: start, pcm: Uint8List.fromList(pcm));
  }
}

/// The root mean square of 16-bit [pcm], 0 to 1: a level meter's value.
double pcmLevel(Uint8List pcm) {
  if (pcm.length < 2) return 0;
  final view = ByteData.sublistView(pcm);
  var sum = 0.0;
  final n = pcm.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final s = view.getInt16(i * 2, Endian.little) / 32768;
    sum += s * s;
  }
  return (math.sqrt(sum / n) * 5).clamp(0.0, 1.0);
}

/// What became of one window.
enum WindowVerdict { pending, listening, none, question, skipped, failed }

/// A window of the meeting, and what the models made of it.
final class MeetingWindow {
  MeetingWindow({required this.index, required this.start, required this.pcm});

  final int index;
  final Duration start;
  final Uint8List pcm;

  Duration get end => start + pcmDuration(pcm);

  WindowVerdict verdict = WindowVerdict.pending;

  /// The question heard in it.
  String? question;

  /// How long embedding it into the meeting index took.
  Duration? embedTook;

  /// How long the language model took to hear it.
  Duration? heardIn;

  String? error;
}

/// [bars] RMS levels (0 to 1) across 16-bit [pcm]: a voice bubble's
/// waveform.
List<double> waveformLevels(Uint8List pcm, {int bars = 40}) {
  final samples = pcm.length ~/ 2;
  if (samples == 0) return const [];
  final per = math.max(1, samples ~/ bars);
  return [
    for (var b = 0; b < bars && b * per < samples; b++)
      pcmLevel(
        Uint8List.sublistView(
          pcm,
          b * per * 2,
          math.min(samples, (b + 1) * per) * 2,
        ),
      ),
  ];
}
