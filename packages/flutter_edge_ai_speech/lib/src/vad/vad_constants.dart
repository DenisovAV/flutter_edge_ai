// The numbers every VAD file shares, native and web arms alike. Pure Dart.
library;

/// The only rate the bundled model runs at.
const int vadSampleRate = 16000;

/// Samples per Silero VAD frame at 16 kHz (32 ms).
const int vadFrameSamples = 512;

/// The audio one frame covers.
const Duration vadFrameDuration = Duration(
  microseconds: vadFrameSamples * 1000000 ~/ vadSampleRate,
);

/// [samples] at 16 kHz as a [Duration], exact to the microsecond.
Duration vadSamplesToDuration(int samples) =>
    Duration(microseconds: samples * 1000000 ~/ vadSampleRate);
