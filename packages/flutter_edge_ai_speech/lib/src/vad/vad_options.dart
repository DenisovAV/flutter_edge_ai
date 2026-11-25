// The endpointing policy a VoiceActivityDetector applies to Silero VAD's
// per-frame speech probabilities. Pure Dart, safe on every platform.
//
// The model only says, every 32 ms, how likely the frame is speech. Turning
// that into "speech started" and "the utterance ended" is a separate policy:
// thresholds with hysteresis, a minimum speech length that drops clicks and
// coughs, a silence that ends an utterance, padding around it and a cap. The
// defaults for the threshold, the hysteresis, the minimum speech and the
// padding are those of Silero's own reference iterator and segmenter
// (`VADIterator` / `get_speech_timestamps` in silero-vad's `utils_vad.py`);
// the minimum silence and the cap are this package's, chosen for a voice turn.
library;

/// How a VoiceActivityDetector turns speech probabilities into events.
final class VadOptions {
  /// Creates a policy. Every argument is checked by [validate], which the
  /// detector calls when it is created.
  const VadOptions({
    this.threshold = 0.5,
    this.negativeThreshold,
    this.minSpeech = const Duration(milliseconds: 250),
    this.minSilence = const Duration(milliseconds: 600),
    this.speechPad = const Duration(milliseconds: 30),
    this.maxUtterance = const Duration(seconds: 30),
  });

  /// A frame whose probability is at least this is speech.
  final double threshold;

  /// While speech is on, a frame below this is silence. Between this and
  /// [threshold] nothing changes, so a voice that wavers around [threshold]
  /// does not end the utterance. `null` means `threshold - 0.15`, at least
  /// 0.01, as in Silero's reference iterator.
  final double? negativeThreshold;

  /// Speech shorter than this is dropped: no event is emitted for it. A start
  /// is therefore reported this long after the voice began, timed back to
  /// where it began.
  final Duration minSpeech;

  /// Silence this long ends an utterance.
  final Duration minSilence;

  /// Kept on both sides of an utterance, so its first and last sounds are not
  /// cut.
  final Duration speechPad;

  /// An utterance this long is ended even if the speaker goes on; the next
  /// speech frame starts a new one.
  final Duration maxUtterance;

  /// [negativeThreshold] with its default applied.
  double get effectiveNegativeThreshold =>
      negativeThreshold ?? (threshold - 0.15 < 0.01 ? 0.01 : threshold - 0.15);

  /// Throws [ArgumentError] naming the first value that cannot work.
  void validate() {
    if (!(threshold > 0 && threshold < 1)) {
      throw ArgumentError.value(threshold, 'threshold', 'must be in (0, 1)');
    }
    final negative = effectiveNegativeThreshold;
    if (!(negative > 0 && negative <= threshold)) {
      // With no explicit value, only a threshold below 0.01 fails here: the
      // default is at least 0.01. Name the value the caller actually set.
      throw negativeThreshold == null
          ? ArgumentError.value(
              threshold,
              'threshold',
              'is below the default negativeThreshold ($negative); set '
                  'negativeThreshold explicitly',
            )
          : ArgumentError.value(
              negativeThreshold,
              'negativeThreshold',
              'must be in (0, threshold]',
            );
    }
    for (final (name, value) in [
      ('minSpeech', minSpeech),
      ('minSilence', minSilence),
      ('speechPad', speechPad),
    ]) {
      if (value.isNegative) {
        throw ArgumentError.value(value, name, 'must not be negative');
      }
    }
    if (maxUtterance <= minSpeech) {
      throw ArgumentError.value(
        maxUtterance,
        'maxUtterance',
        'must be longer than minSpeech ($minSpeech)',
      );
    }
  }

  @override
  String toString() =>
      'VadOptions(threshold: $threshold, negativeThreshold: '
      '$effectiveNegativeThreshold, minSpeech: $minSpeech, minSilence: '
      '$minSilence, speechPad: $speechPad, maxUtterance: $maxUtterance)';
}
