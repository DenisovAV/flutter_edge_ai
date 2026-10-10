import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SamplingParams.forModelType', () {
    test('Gemma families use Google generation_config values', () {
      for (final type in [
        ModelType.gemmaIt,
        ModelType.gemma4,
        ModelType.functionGemma,
      ]) {
        expect(
          SamplingParams.forModelType(type),
          const SamplingParams(temperature: 1.0, topK: 64, topP: 0.95),
          reason: '$type',
        );
      }
    });

    test('Qwen picks the set for thinking on or off', () {
      for (final type in [ModelType.qwen, ModelType.qwen3]) {
        expect(
          SamplingParams.forModelType(type),
          const SamplingParams(temperature: 0.7, topK: 20, topP: 0.8),
          reason: '$type',
        );
        expect(
          SamplingParams.forModelType(type, thinking: true),
          const SamplingParams(temperature: 0.6, topK: 20, topP: 0.95),
          reason: '$type',
        );
      }
      expect(
        SamplingParams.forModelType(ModelType.qwen35, thinking: true),
        const SamplingParams(temperature: 1.0, topK: 20, topP: 0.95),
      );
      expect(
        SamplingParams.forModelType(ModelType.qwen35),
        const SamplingParams(temperature: 0.7, topK: 20, topP: 0.8),
      );
    });

    test('DeepSeek and Llama take top-k 50 where the publisher sets none', () {
      expect(
        SamplingParams.forModelType(ModelType.deepSeek),
        const SamplingParams(temperature: 0.6, topK: 50, topP: 0.95),
      );
      expect(
        SamplingParams.forModelType(ModelType.llama),
        const SamplingParams(temperature: 0.6, topK: 50, topP: 0.9),
      );
    });

    test('Phi and Hammer decode greedily, as their publishers do', () {
      for (final type in [ModelType.phi, ModelType.hammer]) {
        expect(SamplingParams.forModelType(type).topK, 1, reason: '$type');
      }
    });

    test('general has no family values', () {
      expect(SamplingParams.forModelType(ModelType.general).isEmpty, isTrue);
    });
  });

  group('SamplingParams.resolve', () {
    test('every model type resolves to a complete sampler', () {
      for (final type in ModelType.values) {
        for (final thinking in [false, true]) {
          final r = SamplingParams.resolve(
            const SamplingParams(),
            modelType: type,
            thinking: thinking,
          );
          expect(r.topK, greaterThan(0), reason: '$type');
          expect(r.temperature, greaterThan(0), reason: '$type');
          expect(r.topP, inExclusiveRange(0, 1.0001), reason: '$type');
        }
      }
    });

    test('general falls back to topK 40', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(),
          modelType: ModelType.general,
        ),
        const ResolvedSampling(
          temperature: 0.8,
          topK: 40,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
    });

    test('a value the caller sets wins over everything', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(
            temperature: 0.2,
            topK: 3,
            topP: 0.5,
            randomSeed: 7,
          ),
          modelType: ModelType.gemma4,
          modelDefaults: const SamplingParams(
            temperature: 0.6,
            topK: 20,
            topP: 0.95,
          ),
        ),
        const ResolvedSampling(
          temperature: 0.2,
          topK: 3,
          topP: 0.5,
          randomSeed: 7,
        ),
      );
    });

    test('merges field by field: caller, model file, family, fallback', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(temperature: 0.2),
          modelType: ModelType.gemma4,
          modelDefaults: const SamplingParams(topK: 20),
        ),
        const ResolvedSampling(
          temperature: 0.2,
          topK: 20,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
    });

    test('a temperature alone skips a greedy family to the fallback', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(temperature: 0.9),
          modelType: ModelType.phi,
        ),
        const ResolvedSampling(
          temperature: 0.9,
          topK: 40,
          topP: 0.95,
          randomSeed: 1,
        ),
      );
    });

    test('a top-p alone skips a greedy model file to the family', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(topP: 0.9),
          modelType: ModelType.gemma4,
          modelDefaults: const SamplingParams(topK: 1),
        ),
        const ResolvedSampling(
          temperature: 1.0,
          topK: 64,
          topP: 0.9,
          randomSeed: 1,
        ),
      );
    });

    test('nothing set keeps a greedy family greedy', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(),
          modelType: ModelType.phi,
        ).topK,
        1,
      );
    });

    test('temperature 0 asks for greedy, so no layer is skipped', () {
      for (final explicit in const [
        SamplingParams(temperature: 0),
        SamplingParams(temperature: 0, topP: 0.9),
      ]) {
        expect(
          SamplingParams.resolve(explicit, modelType: ModelType.phi).topK,
          1,
          reason: '$explicit',
        );
      }
    });

    test('values no engine can sample with throw', () {
      for (final bad in const [
        SamplingParams(temperature: -0.1),
        SamplingParams(temperature: double.nan),
        SamplingParams(topK: 0),
        SamplingParams(topP: 0),
        SamplingParams(topP: 1.5),
      ]) {
        expect(
          () => SamplingParams.resolve(bad, modelType: ModelType.gemma4),
          throwsArgumentError,
          reason: '$bad',
        );
      }
    });

    test('the model file wins over the family', () {
      expect(
        SamplingParams.resolve(
          const SamplingParams(),
          modelType: ModelType.qwen3,
          modelDefaults: const SamplingParams(
            temperature: 0.6,
            topK: 20,
            topP: 0.95,
          ),
        ).temperature,
        0.6,
      );
    });
  });

  test('isGreedy is a top-k of 1 or a temperature of 0', () {
    expect(const SamplingParams(topK: 1).isGreedy, isTrue);
    expect(const SamplingParams(temperature: 0).isGreedy, isTrue);
    expect(const SamplingParams(temperature: 0.7, topK: 20).isGreedy, isFalse);
    expect(const SamplingParams().isGreedy, isFalse);
  });

  test('orElse keeps set fields and fills unset ones', () {
    expect(
      const SamplingParams(
        topK: 5,
      ).orElse(const SamplingParams(temperature: 0.3, topK: 9)),
      const SamplingParams(temperature: 0.3, topK: 5),
    );
  });
}
