// Pins the legacy URL -> ModelSource mapping behind the deprecated
// InferenceModelSpec.fromLegacyUrl (removed in 2.5.0). model_spec_test.dart
// covers the factory too, but only in a browser.

import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('modelSourceFromLegacyUrl', () {
    test('http(s) is a network source', () {
      expect(
        modelSourceFromLegacyUrl('https://example.com/m.task'),
        NetworkSource('https://example.com/m.task'),
      );
      expect(
        modelSourceFromLegacyUrl('http://example.com/m.task'),
        NetworkSource('http://example.com/m.task'),
      );
    });

    test('asset:// and a schemeless path are assets', () {
      expect(
        modelSourceFromLegacyUrl('asset://assets/models/m.task'),
        ModelSource.asset('assets/models/m.task'),
      );
      expect(
        modelSourceFromLegacyUrl('assets/models/m.task'),
        ModelSource.asset('assets/models/m.task'),
      );
    });

    test('native:// is bundled, file:// is a file', () {
      expect(
        modelSourceFromLegacyUrl('native://m.task'),
        ModelSource.bundled('m.task'),
      );
      expect(
        modelSourceFromLegacyUrl('file:///data/m.task'),
        ModelSource.file('/data/m.task'),
      );
    });
  });

  test('InferenceModelSpec.fromLegacyUrl equals the explicit constructor', () {
    final legacy = InferenceModelSpec.fromLegacyUrl(
      name: 'm',
      modelUrl: 'https://example.com/m.task',
      loraUrl: 'file:///data/lora.bin',
    );
    final explicit = InferenceModelSpec(
      name: 'm',
      modelSource: ModelSource.network('https://example.com/m.task'),
      loraSource: ModelSource.file('/data/lora.bin'),
      modelType: ModelType.general,
    );
    expect(legacy, explicit);
  });
}
