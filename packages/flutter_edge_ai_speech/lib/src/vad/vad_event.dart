// What a VoiceActivityDetector reports. Pure Dart, safe on every platform.
library;

/// The rate every sample index here counts at.
const int _rate = 16000;

Duration _at(int sample) => Duration(microseconds: sample * 1000000 ~/ _rate);

/// One change in voice activity.
///
/// Positions are sample indices into the stream passed to
/// `VoiceActivityDetector.detect`, 16 kHz, counted from its first sample:
/// slice the PCM you kept with them (`2 * index` bytes). The [Duration]
/// getters are the same positions in time, truncated to the microsecond.
sealed class VadEvent {
  const VadEvent();
}

/// Speech began at [startSample] (already moved back by
/// `VadOptions.speechPad`, and never before the end of the previous
/// utterance).
///
/// Reported once the speech has lasted `VadOptions.minSpeech`, so it arrives
/// at least that much after it began, and up to `minSpeech + minSilence`
/// plus one 32 ms frame after it when the speech pauses before that (see
/// `VadOptions.minSpeech`). To hand the whole utterance to speech-to-text,
/// keep that much audio, plus `VadOptions.speechPad` and one input chunk.
final class VadSpeechStart extends VadEvent {
  const VadSpeechStart(this.startSample);

  final int startSample;

  Duration get start => _at(startSample);

  @override
  bool operator ==(Object other) =>
      other is VadSpeechStart && other.startSample == startSample;

  @override
  int get hashCode => startSample.hashCode;

  @override
  String toString() => 'VadSpeechStart($start)';
}

/// Why an utterance ended.
enum VadEndReason {
  /// `VadOptions.minSilence` of silence.
  silence,

  /// The utterance reached `VadOptions.maxUtterance`.
  maxUtterance,

  /// The input stream ended during speech.
  inputEnded,
}

/// The utterance that began at [startSample] ended at [endSample], exclusive
/// (padded by `VadOptions.speechPad`, never past the audio received).
final class VadSpeechEnd extends VadEvent {
  const VadSpeechEnd(this.startSample, this.endSample, this.reason);

  final int startSample;
  final int endSample;
  final VadEndReason reason;

  Duration get start => _at(startSample);
  Duration get end => _at(endSample);

  @override
  bool operator ==(Object other) =>
      other is VadSpeechEnd &&
      other.startSample == startSample &&
      other.endSample == endSample &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(startSample, endSample, reason);

  @override
  String toString() => 'VadSpeechEnd($start, $end, ${reason.name})';
}
