@TestOn('!vm')
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';

void main() {
  group('BundledSource Models', () {
    test('createBundledInferenceSpec creates valid spec', () {
      final spec = MobileModelManager.createBundledInferenceSpec(
        resourceName: 'gemma3-270m-it-q8.task',
      );

      expect(spec.name, 'gemma3-270m-it-q8');
      expect(spec.files.length, 1);
      expect(spec.files.first.source, isA<BundledSource>());

      final bundledSource = spec.files.first.source as BundledSource;
      expect(bundledSource.resourceName, 'gemma3-270m-it-q8.task');
      expect(spec.type, ModelManagementType.inference);
    });

    test('createBundledInferenceSpec with LoRA creates valid spec', () {
      final spec = MobileModelManager.createBundledInferenceSpec(
        resourceName: 'gemma3-270m-it-q8.task',
        loraResourceName: 'lora_weights.bin',
      );

      expect(spec.name, 'gemma3-270m-it-q8');
      expect(spec.files.length, 2);

      final modelSource = spec.files[0].source as BundledSource;
      expect(modelSource.resourceName, 'gemma3-270m-it-q8.task');

      final loraSource = spec.files[1].source as BundledSource;
      expect(loraSource.resourceName, 'lora_weights.bin');
    });

    test('createBundledEmbeddingSpec creates valid spec', () {
      final spec = MobileModelManager.createBundledEmbeddingSpec(
        modelResourceName: 'embeddinggemma-300m.tflite',
        tokenizerResourceName: 'sentencepiece.model',
      );

      expect(spec.name, 'embeddinggemma-300m');
      expect(spec.files.length, 2);
      expect(spec.type, ModelManagementType.embedding);

      final modelSource = spec.files[0].source as BundledSource;
      expect(modelSource.resourceName, 'embeddinggemma-300m.tflite');

      final tokenizerSource = spec.files[1].source as BundledSource;
      expect(tokenizerSource.resourceName, 'sentencepiece.model');
    });

    test('BundledSource validation', () {
      final source = BundledSource('valid_resource.task');
      expect(source.resourceName, 'valid_resource.task');
      expect(source.requiresDownload, false);
      expect(source.supportsProgress, false);
      expect(source.supportsResume, false);
    });

    test('BundledSource rejects invalid resource names', () {
      // Path separator not allowed
      expect(
        () => BundledSource('invalid/path.task'),
        throwsA(isA<ArgumentError>()),
      );

      // Spaces not allowed
      expect(
        () => BundledSource('invalid name.task'),
        throwsA(isA<ArgumentError>()),
      );

      // Empty not allowed
      expect(() => BundledSource(''), throwsA(isA<ArgumentError>()));
    });

    test('BundledSource validates LoRA source compatibility', () {
      final source = BundledSource('model.task');
      final loraSource = BundledSource('lora.bin');
      final networkSource = NetworkSource('https://example.com/model.task');

      expect(source.validateLoraSource(loraSource), true);
      expect(source.validateLoraSource(networkSource), false);
    });
  });
}
