import 'package:flutter_gemma_speech/src/litert/mel_filter_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loadMelFilterAsset("whisper_mel_80") returns an [80,201] matrix', () {
    final m = loadMelFilterAsset('whisper_mel_80');
    expect(m.length, 80 * 201);
    // Mel filterbank weights are non-negative triangular weights; a
    // structural sanity check (not a numeric golden — that's Task 1.4's
    // end-to-end log-mel golden, which validates the STFT+matmul+norm
    // pipeline against a Python reference).
    expect(m.any((v) => v > 0), isTrue);
    expect(m.every((v) => v >= 0), isTrue);
  });

  test('unknown asset name throws, naming the asset', () {
    expect(
      () => loadMelFilterAsset('nonexistent'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('nonexistent'),
        ),
      ),
    );
  });

  test('loadMelFilterAsset("nemo_mel_80") returns an [80,257] matrix', () {
    final m = loadMelFilterAsset('nemo_mel_80');
    expect(m.length, 80 * 257);
    // Mel filterbank weights are non-negative triangular weights; a
    // structural sanity check (not a numeric golden — that's Task 1.3's
    // end-to-end computeNemoLogMel golden, which validates the
    // STFT+matmul+log+norm pipeline against a Python reference).
    expect(m.any((v) => v > 0), isTrue);
    expect(m.every((v) => v >= 0), isTrue);
  });
}
