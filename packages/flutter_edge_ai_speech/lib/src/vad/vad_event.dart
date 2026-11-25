// What a VoiceActivityDetector reports. Pure Dart, safe on every platform.
library;

/// One change in voice activity. Times count from the first sample of the
/// stream passed to `VoiceActivityDetector.detect`, from the samples
/// themselves, not from a clock.
sealed class VadEvent {
  const VadEvent();
}

/// Speech began at [start] (already moved back by `VadOptions.speechPad`).
///
/// Reported once the speech has lasted `VadOptions.minSpeech`, so it arrives
/// that much after [start]; keep at least that much audio to hand the whole
/// utterance to speech-to-text.
final class VadSpeechStart extends VadEvent {
  const VadSpeechStart(this.start);

  final Duration start;

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

/// The utterance that began at [start] ended at [end] (padded by
/// `VadOptions.speechPad`, never past the audio received).
final class VadSpeechEnd extends VadEvent {
  const VadSpeechEnd(this.start, this.end, this.reason);

  final Duration start;
  final Duration end;
  final VadEndReason reason;

  @override
  String toString() => 'VadSpeechEnd($start, $end, ${reason.name})';
}
