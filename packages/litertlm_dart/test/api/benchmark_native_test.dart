// benchmark() on real models (opt-in): Kotlin's loraConfig and
// repetitionPenaltyConfig.
//
//   FUNCTIONGEMMA_LORA_LITERTLM  FunctionGemma 270M exported with LoRA input
//                                signatures (LiteRT-LM's LoRA Colab, step 3)
//   FUNCTIONGEMMA_TASK_LORA      the Colab's task adapter (.tflite)
//   GEMMA4_E2B_LITERTLM          Gemma 4 E2B (.litertlm), for the penalty run
//   LITERTLM_BENCH_BACKEND       cpu (default) or gpu
//   LITERTLM_BENCH_CACHE_DIR     the engines' cache directory
//
// Prints every result, for the record.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

String? _file(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

void main() {
  final loraModel = _file('FUNCTIONGEMMA_LORA_LITERTLM');
  final adapter = _file('FUNCTIONGEMMA_TASK_LORA');
  final gemma4 = _file('GEMMA4_E2B_LITERTLM');
  final gpu = Platform.environment['LITERTLM_BENCH_BACKEND'] == 'gpu';
  final backend = gpu ? const Backend.gpu() : const Backend.cpu();
  final tag = gpu ? 'gpu' : 'cpu';
  final cacheDir = Platform.environment['LITERTLM_BENCH_CACHE_DIR'];

  test(
    'FunctionGemma with and without its LoRA ($tag)',
    skip: loraModel == null || adapter == null
        ? 'FUNCTIONGEMMA_LORA_LITERTLM and FUNCTIONGEMMA_TASK_LORA'
        : null,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      // Twice each, alternating: the first run of a process loads cold.
      final withAdapter = LoraConfig(loraPath: adapter);
      for (final lora in [null, withAdapter, null, withAdapter]) {
        final result = await benchmark(
          modelPath: loraModel!,
          backend: backend,
          prefillTokens: 128,
          decodeTokens: 64,
          maxNumTokens: 1024,
          cacheDir: cacheDir,
          loraConfig: lora,
        );
        print(
          '[bench functiongemma $tag ${lora == null ? 'base' : 'lora'}] '
          '$result',
        );
        expect(result.prefillTokenCount, 128);
        expect(result.decodeTokenCount, 64);
      }
    },
  );

  test(
    'Gemma 4 E2B with and without a repetition penalty ($tag)',
    skip: gemma4 == null ? 'GEMMA4_E2B_LITERTLM' : null,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final penalties = RepetitionPenaltyConfig(
        repetitionPenalty: 1.3,
        presencePenalty: 0.5,
        frequencyPenalty: 0.5,
      );
      for (final penalty in [null, penalties, null, penalties]) {
        final result = await benchmark(
          modelPath: gemma4!,
          backend: backend,
          prefillTokens: 256,
          decodeTokens: 128,
          maxNumTokens: 1024,
          cacheDir: cacheDir,
          repetitionPenaltyConfig: penalty,
        );
        print(
          '[bench gemma4-e2b $tag ${penalty == null ? 'no penalty' : 'penalty'}] '
          '$result',
        );
        expect(result.prefillTokenCount, 256);
        expect(result.decodeTokenCount, 128);
      }
    },
  );
}
