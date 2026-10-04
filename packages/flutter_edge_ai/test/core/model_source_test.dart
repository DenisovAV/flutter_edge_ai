import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';

void main() {
  group('ModelSource - NetworkSource', () {
    test('creates valid HTTPS source', () {
      final source = ModelSource.network('https://example.com/model.bin');
      expect(source, isA<NetworkSource>());
      expect(
        (source as NetworkSource).url,
        equals('https://example.com/model.bin'),
      );
      expect(source.isSecure, isTrue);
      expect(source.requiresDownload, isTrue);
      expect(source.supportsProgress, isTrue);
      expect(source.supportsResume, isTrue);
    });

    test('creates valid HTTP source', () {
      final source = ModelSource.network('http://example.com/model.bin');
      expect(source, isA<NetworkSource>());
      expect((source as NetworkSource).isSecure, isFalse);
    });

    test('throws for invalid URL', () {
      expect(() => ModelSource.network(''), throwsArgumentError);
      expect(() => ModelSource.network('invalid'), throwsArgumentError);
      expect(
        () => ModelSource.network('ftp://example.com'),
        throwsArgumentError,
      );
    });

    test('validates LoRA source compatibility', () {
      final source = ModelSource.network('https://example.com/model.bin');
      final loraNetwork = ModelSource.network('https://example.com/lora.bin');
      final loraAsset = ModelSource.asset('assets/lora.bin');

      expect(source.validateLoraSource(loraNetwork), isTrue);
      expect(source.validateLoraSource(loraAsset), isFalse);
    });

    test('equality works correctly', () {
      final source1 = ModelSource.network('https://example.com/model.bin');
      final source2 = ModelSource.network('https://example.com/model.bin');
      final source3 = ModelSource.network('https://example.com/other.bin');

      expect(source1, equals(source2));
      expect(source1.hashCode, equals(source2.hashCode));
      expect(source1, isNot(equals(source3)));
    });
  });

  group('ModelSource - AssetSource', () {
    test('creates valid asset source', () {
      final source = ModelSource.asset('assets/models/demo.bin');
      expect(source, isA<AssetSource>());
      expect((source as AssetSource).path, equals('assets/models/demo.bin'));
      expect(source.normalizedPath, equals('assets/models/demo.bin'));
      expect(source.requiresDownload, isFalse);
      expect(source.supportsProgress, isTrue);
      expect(source.supportsResume, isFalse);
    });

    test('normalizes path without assets/ prefix', () {
      final source = ModelSource.asset('models/demo.bin');
      expect(
        (source as AssetSource).normalizedPath,
        equals('assets/models/demo.bin'),
      );
    });

    test('handles leading slash', () {
      final source = ModelSource.asset('/assets/models/demo.bin');
      expect(
        (source as AssetSource).normalizedPath,
        equals('assets/models/demo.bin'),
      );
    });

    test('throws for invalid paths', () {
      expect(() => ModelSource.asset(''), throwsArgumentError);
      expect(() => ModelSource.asset('../outside'), throwsArgumentError);
      expect(
        () => ModelSource.asset('http://example.com'),
        throwsArgumentError,
      );
    });

    test('validates asset LoRA compatibility', () {
      final source = ModelSource.asset('assets/models/demo.bin');
      final loraAsset = ModelSource.asset('assets/lora.bin');
      final loraNetwork = ModelSource.network('https://example.com/lora.bin');

      expect(source.validateLoraSource(loraAsset), isTrue);
      expect(source.validateLoraSource(loraNetwork), isFalse);
    });

    test('equality works correctly', () {
      final source1 = ModelSource.asset('models/demo.bin');
      final source2 = ModelSource.asset('assets/models/demo.bin');
      final source3 = ModelSource.asset('models/other.bin');

      expect(source1, equals(source2)); // Normalized paths are equal
      expect(source1, isNot(equals(source3)));
    });
  });

  group('ModelSource - BundledSource', () {
    test('creates valid bundled source', () {
      final source = ModelSource.bundled('production_gemma_7b');
      expect(source, isA<BundledSource>());
      expect(
        (source as BundledSource).resourceName,
        equals('production_gemma_7b'),
      );
      expect(source.requiresDownload, isFalse);
      expect(source.supportsProgress, isFalse);
      expect(source.supportsResume, isFalse);
    });

    test('validates resource name format', () {
      expect(() => ModelSource.bundled(''), throwsArgumentError);
      expect(() => ModelSource.bundled('invalid/path'), throwsArgumentError);
      expect(() => ModelSource.bundled('with spaces'), throwsArgumentError);
      // Note: Uppercase is now allowed for real-world file names
    });

    test('validates bundled LoRA compatibility', () {
      final source = ModelSource.bundled('production_gemma_7b');
      final loraBundled = ModelSource.bundled('production_lora');
      final loraAsset = ModelSource.asset('assets/lora.bin');

      expect(source.validateLoraSource(loraBundled), isTrue);
      expect(source.validateLoraSource(loraAsset), isFalse);
    });

    test('equality works correctly', () {
      final source1 = ModelSource.bundled('production_gemma_7b');
      final source2 = ModelSource.bundled('production_gemma_7b');
      final source3 = ModelSource.bundled('other_model');

      expect(source1, equals(source2));
      expect(source1.hashCode, equals(source2.hashCode));
      expect(source1, isNot(equals(source3)));
    });
  });

  group('ModelSource - FileSource', () {
    test('creates valid file source', () {
      final source = ModelSource.file('/tmp/model.bin');
      expect(source, isA<FileSource>());
      expect((source as FileSource).path, equals('/tmp/model.bin'));
      expect(source.requiresDownload, isFalse);
      expect(source.supportsProgress, isFalse);
      expect(source.supportsResume, isFalse);
    });

    test('throws for relative paths', () {
      expect(() => ModelSource.file('relative/path.bin'), throwsArgumentError);
      expect(() => ModelSource.file(''), throwsArgumentError);
      expect(() => ModelSource.file('./file.bin'), throwsArgumentError);
    });

    test('accepts Windows absolute paths', () {
      final source = ModelSource.file(r'C:\temp\model.bin');
      expect(source, isA<FileSource>());
      expect((source as FileSource).path, equals(r'C:\temp\model.bin'));

      final source2 = ModelSource.file(r'D:\models\gemma.litertlm');
      expect((source2 as FileSource).path, equals(r'D:\models\gemma.litertlm'));
    });

    test('validates file LoRA compatibility', () {
      final source = ModelSource.file('/tmp/model.bin');
      final loraFile = ModelSource.file('/tmp/lora.bin');
      final loraAsset = ModelSource.asset('assets/lora.bin');

      expect(source.validateLoraSource(loraFile), isTrue);
      expect(source.validateLoraSource(loraAsset), isFalse);
    });

    test('equality works correctly', () {
      final source1 = ModelSource.file('/tmp/model.bin');
      final source2 = ModelSource.file('/tmp/model.bin');
      final source3 = ModelSource.file('/tmp/other.bin');

      expect(source1, equals(source2));
      expect(source1.hashCode, equals(source2.hashCode));
      expect(source1, isNot(equals(source3)));
    });
  });

  group('ModelSource - Pattern Matching', () {
    test('supports switch expressions', () {
      final sources = [
        ModelSource.network('https://example.com/model.bin'),
        ModelSource.asset('assets/models/demo.bin'),
        ModelSource.bundled('production_gemma_7b'),
        ModelSource.file('/tmp/model.bin'),
      ];

      final types = sources
          .map(
            (source) => switch (source) {
              NetworkSource() => 'network',
              AssetSource() => 'asset',
              BundledSource() => 'bundled',
              FileSource() => 'file',
            },
          )
          .toList();

      expect(types, equals(['network', 'asset', 'bundled', 'file']));
    });

    test('supports destructuring patterns', () {
      final source = ModelSource.network('https://example.com/model.bin');

      switch (source) {
        case NetworkSource(:final url, :final isSecure):
          expect(url, equals('https://example.com/model.bin'));
          expect(isSecure, isTrue);
        default:
          fail('Should match NetworkSource');
      }
    });
  });
}
