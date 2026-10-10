import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/engine_sampler_latch.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaults = ResolvedSampling(
  temperature: 1.0,
  topK: 64,
  topP: 0.95,
  randomSeed: 1,
);
const _greedy = ResolvedSampling(
  temperature: 0.8,
  topK: 1,
  topP: 0.95,
  randomSeed: 1,
);
const _thinking = ResolvedSampling(
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
}
