import 'package:litertlm_dart/src/ffi/engine_sampler_latch.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_runtime_check.dart'
    show liteRtLmSamplerFixedAtFirstGeneration;
import 'package:test/test.dart';
import 'package:litertlm_dart/src/runtime/types.dart';

const _defaults = Sampler(
  temperature: 1.0,
  topK: 64,
  topP: 0.95,
  randomSeed: 1,
);
const _greedy = Sampler(temperature: 0.8, topK: 1, topP: 0.95, randomSeed: 1);
const _thinking = Sampler(
  temperature: 0.6,
  topK: 20,
  topP: 0.95,
  randomSeed: 1,
);

void main() {
  late EngineSamplerLatch latch;
  setUp(() => latch = EngineSamplerLatch());

  test('the first generation fixes the sampler; the same one is quiet', () {
    expect(latch.onGeneration(_defaults, explicit: false), isNull);
    expect(latch.onGeneration(_defaults, explicit: true), isNull);
  });

  test('a later explicit sampler warns, once per engine', () {
    latch.onGeneration(_defaults, explicit: false);
    final note = latch.onGeneration(_greedy, explicit: true);
    expect(note?.warn, isTrue);
    expect(note?.message, contains('topK: 64'));
    expect(latch.onGeneration(_greedy, explicit: true), isNull);
  });

  test('defaults after an explicit first sampler warn too', () {
    latch.onGeneration(_greedy, explicit: true);
    expect(latch.onGeneration(_defaults, explicit: false)?.warn, isTrue);
  });

  test('defaults after defaults only go to the verbose log', () {
    latch.onGeneration(_defaults, explicit: false);
    final note = latch.onGeneration(_thinking, explicit: false);
    expect(note?.warn, isFalse);
  });

  test('reset forgets the sampler and the warning', () {
    latch.onGeneration(_defaults, explicit: false);
    latch.onGeneration(_greedy, explicit: true);
    latch.reset();
    expect(latch.onGeneration(_greedy, explicit: true), isNull);
    expect(latch.onGeneration(_defaults, explicit: true)?.warn, isTrue);
  });

  test('only a native library of C API 1.0 (LiteRT-LM 0.19) keeps the first '
      "generation's sampler; from 1.1 (0.20) the latch is not consulted", () {
    expect(
      liteRtLmSamplerFixedAtFirstGeneration((
        code: 0,
        major: 1,
        minor: 0,
        patch: 0,
      )),
      isTrue,
    );
    for (final minor in [1, 2]) {
      expect(
        liteRtLmSamplerFixedAtFirstGeneration((
          code: 0,
          major: 1,
          minor: minor,
          patch: 0,
        )),
        isFalse,
        reason: '1.$minor',
      );
    }
    // A version that cannot be read keeps the warning.
    expect(
      liteRtLmSamplerFixedAtFirstGeneration((
        code: 13,
        major: 0,
        minor: 0,
        patch: 0,
      )),
      isTrue,
    );
  });
}
