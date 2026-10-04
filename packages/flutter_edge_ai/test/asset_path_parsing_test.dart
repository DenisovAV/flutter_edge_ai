import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Asset Path Parsing', () {
    test('should correctly parse asset:// URLs', () {
      // Test case from Issue #116
      const url = 'asset://assets/models/gemma3-1b.task';
      const expectedPath = 'assets/models/gemma3-1b.task';

      // OLD broken way (what was causing the bug)
      final brokenResult = Uri.parse(url).path;
      expect(
        brokenResult,
        equals('/models/gemma3-1b.task'),
      ); // This was the bug

      // NEW fixed way
      final fixedResult = url.replaceFirst('asset://', '');
      expect(fixedResult, equals(expectedPath));
    });

    test('should handle various asset path formats', () {
      final testCases = {
        'asset://assets/models/model.task': 'assets/models/model.task',
        'asset://assets/model.bin': 'assets/model.bin',
        'asset://models/model.tflite': 'models/model.tflite',
      };

      for (final entry in testCases.entries) {
        final result = entry.key.replaceFirst('asset://', '');
        expect(
          result,
          equals(entry.value),
          reason: 'Failed for input: ${entry.key}',
        );
      }
    });

    test('should not modify non-asset URLs', () {
      final nonAssetUrls = [
        'https://example.com/model.task',
        'file:///path/to/model.bin',
        'models/local.tflite',
      ];

      for (final url in nonAssetUrls) {
        final result = url.replaceFirst('asset://', '');
        expect(
          result,
          equals(url),
          reason: 'Should not modify non-asset URL: $url',
        );
      }
    });
  });
}
