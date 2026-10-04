import 'dart:typed_data';

/// Utility class for audio format conversion.
///
/// Gemma 3n E4B requires: PCM 16kHz, 16-bit, mono
class AudioConverter {
  /// Target sample rate for Gemma 3n E4B
  static const int targetSampleRate = 16000;

  /// Bytes per sample (16-bit = 2 bytes)
  static const int bytesPerSample = 2;

  /// Convert PCM audio to 16kHz mono format.
  ///
  /// [pcmData] - Raw PCM data (16-bit signed, little-endian)
  /// [sourceSampleRate] - Original sample rate (e.g., 44100, 48000)
  /// [sourceChannels] - Number of channels (1 = mono, 2 = stereo)
  ///
  /// Returns PCM data at 16kHz, 16-bit, mono
  static Uint8List toPCM16kHzMono(
    Uint8List pcmData, {
    required int sourceSampleRate,
    int sourceChannels = 1,
  }) {
    // If already in target format, return as-is
    if (sourceSampleRate == targetSampleRate && sourceChannels == 1) {
      return pcmData;
    }

    // Convert bytes to 16-bit samples
    final samples = _bytesToSamples(pcmData);

    // Convert stereo to mono if needed
    final monoSamples = sourceChannels == 2 ? _stereoToMono(samples) : samples;

    // Resample to 16kHz if needed
    final resampledSamples = sourceSampleRate != targetSampleRate
        ? _resample(monoSamples, sourceSampleRate, targetSampleRate)
        : monoSamples;

    // Convert back to bytes
    return _samplesToBytes(resampledSamples);
  }

  /// Extract raw PCM from WAV file data.
  ///
  /// Returns a record with PCM data, sample rate, and channels.
  static ({Uint8List pcmData, int sampleRate, int channels}) parseWav(
    Uint8List wavData,
  ) {
    // WAV header structure (standard layout):
    // 0-3: "RIFF"
    // 4-7: file size
    // 8-11: "WAVE"
    // Then chunks: "fmt ", "data", etc.
    // Note: macOS Core Audio may add extra chunks, so we search for them

    if (wavData.length < 44) {
      throw ArgumentError('Invalid WAV data: too short');
    }

    final byteData = ByteData.sublistView(wavData);

    // Verify RIFF header
    final riff = String.fromCharCodes(wavData.sublist(0, 4));
    if (riff != 'RIFF') {
      throw ArgumentError('Invalid WAV: missing RIFF header');
    }

    // Verify WAVE format
    final wave = String.fromCharCodes(wavData.sublist(8, 12));
    if (wave != 'WAVE') {
      throw ArgumentError('Invalid WAV: missing WAVE format');
    }

    // Search for chunks starting after WAVE header
    int offset = 12;
    int sampleRate = 0;
    int channels = 0;
    Uint8List? pcmData;

    while (offset < wavData.length - 8) {
      final chunkId = String.fromCharCodes(wavData.sublist(offset, offset + 4));
      final chunkSize = byteData.getUint32(offset + 4, Endian.little);
      final chunkDataStart = offset + 8;

      if (chunkId == 'fmt ') {
        // Format chunk found
        // Offset 0-1: audio format (1 = PCM)
        // Offset 2-3: number of channels
        // Offset 4-7: sample rate
        channels = byteData.getUint16(chunkDataStart + 2, Endian.little);
        sampleRate = byteData.getUint32(chunkDataStart + 4, Endian.little);
      } else if (chunkId == 'data') {
        // Data chunk found
        pcmData = Uint8List.fromList(
          wavData.sublist(chunkDataStart, chunkDataStart + chunkSize),
        );
      }

      // Move to next chunk
      offset = chunkDataStart + chunkSize;
      // Align to even byte
      if (chunkSize % 2 != 0) offset++;
    }

    if (pcmData == null) {
      throw ArgumentError('Invalid WAV: data chunk not found');
    }

    if (sampleRate == 0 || channels == 0) {
      throw ArgumentError('Invalid WAV: fmt chunk not found or invalid');
    }

    return (pcmData: pcmData, sampleRate: sampleRate, channels: channels);
  }

  /// Create WAV file from PCM data.
  ///
  /// [pcmData] - Raw PCM data (16-bit signed, little-endian)
  /// [sampleRate] - Sample rate in Hz (default 16000)
  /// [channels] - Number of channels (default 1 = mono)
  /// [bitsPerSample] - Bits per sample (default 16)
  ///
  /// Returns complete WAV file with header
  static Uint8List pcmToWav(
    Uint8List pcmData, {
    int sampleRate = 16000,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final header = Uint8List(44);
    final byteData = ByteData.sublistView(header);

    // RIFF header
    header.setAll(0, 'RIFF'.codeUnits);
    byteData.setUint32(4, fileSize, Endian.little);
    header.setAll(8, 'WAVE'.codeUnits);

    // fmt chunk
    header.setAll(12, 'fmt '.codeUnits);
    byteData.setUint32(16, 16, Endian.little); // chunk size
    byteData.setUint16(20, 1, Endian.little); // audio format (PCM)
    byteData.setUint16(22, channels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    header.setAll(36, 'data'.codeUnits);
    byteData.setUint32(40, dataSize, Endian.little);

    // Combine header + PCM data
    final wav = Uint8List(44 + dataSize);
    wav.setAll(0, header);
    wav.setAll(44, pcmData);

    return wav;
  }

  /// Calculate audio duration from PCM data.
  ///
  /// [pcmData] - Raw PCM data
  /// [sampleRate] - Sample rate in Hz
  /// [channels] - Number of audio channels
  /// [bitsPerSample] - Bits per sample (default 16)
  static Duration calculateDuration(
    Uint8List pcmData, {
    required int sampleRate,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final bytesPerSample = bitsPerSample ~/ 8;
    final totalSamples = pcmData.length ~/ (bytesPerSample * channels);
    final seconds = totalSamples / sampleRate;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Format duration as "mm:ss" string.
  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // Private helper methods

  static Int16List _bytesToSamples(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    final samples = Int16List(bytes.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  static Uint8List _samplesToBytes(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final byteData = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      byteData.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }

  static Int16List _stereoToMono(Int16List stereoSamples) {
    final monoSamples = Int16List(stereoSamples.length ~/ 2);
    for (var i = 0; i < monoSamples.length; i++) {
      // Average left and right channels
      final left = stereoSamples[i * 2];
      final right = stereoSamples[i * 2 + 1];
      monoSamples[i] = ((left + right) ~/ 2).toInt();
    }
    return monoSamples;
  }

  static Int16List _resample(
    Int16List samples,
    int sourceSampleRate,
    int targetSampleRate,
  ) {
    final ratio = sourceSampleRate / targetSampleRate;
    final newLength = (samples.length / ratio).round();
    final resampled = Int16List(newLength);

    for (var i = 0; i < newLength; i++) {
      final srcIndex = (i * ratio).floor();
      final srcIndexNext = (srcIndex + 1).clamp(0, samples.length - 1);
      final fraction = (i * ratio) - srcIndex;

      // Linear interpolation
      final value =
          samples[srcIndex] * (1 - fraction) + samples[srcIndexNext] * fraction;
      resampled[i] = value.round().clamp(-32768, 32767);
    }

    return resampled;
  }
}
