import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai_onnx/src/onnx_sampling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing set leaves the model config alone', () {
    expect(onnxSearchOptions(const SamplingParams()), isEmpty);
  });

  test('a set temperature switches sampling on', () {
    expect(onnxSearchOptions(const SamplingParams(temperature: 0.7)), {
      'do_sample': true,
      'temperature': 0.7,
    });
  });

  test('every field maps to its ORT-GenAI name', () {
    expect(
      onnxSearchOptions(
        const SamplingParams(
          temperature: 0.7,
          topK: 20,
          topP: 0.8,
          randomSeed: 3,
        ),
      ),
      {
        'do_sample': true,
        'temperature': 0.7,
        'top_k': 20,
        'top_p': 0.8,
        'random_seed': 3,
      },
    );
  });

  test('temperature 0 is greedy and is never sent', () {
    expect(onnxSearchOptions(const SamplingParams(temperature: 0, topK: 40)), {
      'do_sample': false,
    });
  });

  test('topK 1 is greedy', () {
    expect(onnxSearchOptions(const SamplingParams(topK: 1)), {
      'do_sample': false,
    });
  });

  test('a seed alone does not switch sampling on', () {
    expect(onnxSearchOptions(const SamplingParams(randomSeed: 5)), {
      'random_seed': 5,
    });
  });

  group('withSamplingTopK', () {
    test('a temperature over a config with top_k 1 gets a top-k', () {
      expect(
        withSamplingTopK(
          const SamplingParams(temperature: 0.7),
          modelType: ModelType.qwen,
          configTopK: 1,
        ),
        const SamplingParams(temperature: 0.7, topK: 20),
      );
    });

    test('a greedy family is skipped for the fallback top-k', () {
      expect(
        withSamplingTopK(
          const SamplingParams(temperature: 0.7),
          modelType: ModelType.phi,
          configTopK: 1,
        ).topK,
        40,
      );
    });

    test('a config that samples keeps its own top-k', () {
      expect(
        withSamplingTopK(
          const SamplingParams(temperature: 0.7),
          modelType: ModelType.qwen,
          configTopK: 50,
        ),
        const SamplingParams(temperature: 0.7),
      );
    });

    test('a top-k the caller set, or greedy, is left alone', () {
      for (final s in const [
        SamplingParams(temperature: 0.7, topK: 5),
        SamplingParams(temperature: 0),
        SamplingParams(randomSeed: 3),
      ]) {
        expect(
          withSamplingTopK(s, modelType: ModelType.qwen, configTopK: 1),
          s,
          reason: '$s',
        );
      }
    });
  });
}
