import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:flutter_edge_ai/src/utils/file_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isLiteRtLmFilename', () {
    test('matches the .litertlm suffix in any ASCII case', () {
      expect(isLiteRtLmFilename('gemma-4-E2B-it.litertlm'), isTrue);
      expect(isLiteRtLmFilename('embeddinggemma.LITERTLM'), isTrue);
      expect(isLiteRtLmFilename('model.LiteRtLm'), isTrue);
      expect(isLiteRtLmFilename('.litertlm'), isTrue);
      expect(isLiteRtLmFilename('/abs/dir/model.litertlm'), isTrue);
    });

    test('rejects every other name', () {
      expect(isLiteRtLmFilename('model.tflite'), isFalse);
      expect(isLiteRtLmFilename('model.task'), isFalse);
      expect(isLiteRtLmFilename('model.litertlm.part'), isFalse);
      expect(isLiteRtLmFilename('litertlm'), isFalse);
      expect(isLiteRtLmFilename('modellitertlm'), isFalse);
      expect(isLiteRtLmFilename(''), isFalse);
    });

    test('folds ASCII only: a non-ASCII look-alike never matches', () {
      // U+0130 is not an ASCII capital, so it is compared as is.
      expect(isLiteRtLmFilename('model.l\u0130tertlm'), isFalse);
      // A trailing non-ASCII code unit is never part of the suffix.
      expect(isLiteRtLmFilename('model.litertlm\u212A'), isFalse);
    });
  });

  test('self-contained GGUF suffix folds ASCII only', () {
    expect(isSelfContainedEmbeddingFilename('model.GgUf'), isTrue);
    expect(isSelfContainedEmbeddingFilename('model.gguf.part'), isFalse);
    expect(isSelfContainedEmbeddingFilename('model.gg\uFF35f'), isFalse);
    expect(isSelfContainedEmbeddingFilename('model.gguf\u212A'), isFalse);
  });

  group('sanitizeHfDirName', () {
    test('is the FileNameUtils helper', () {
      const cases = [
        ('onnx-community/Qwen2.5-0.5B-Instruct', null),
        ('microsoft/Phi-3.5-mini-instruct-onnx', 'cpu_and_mobile/cpu-int4'),
        ('org/name', ''),
      ];
      for (final (repo, variant) in cases) {
        expect(
          sanitizeHfDirName(repo, variant: variant),
          FileNameUtils.sanitizeHfDirName(repo, variant: variant),
        );
      }
      expect(
        sanitizeHfDirName('org/name', variant: 'cpu/int4'),
        'org__name__cpu__int4',
      );
    });

    test('throws for a name that would escape the storage directory', () {
      expect(() => sanitizeHfDirName('..'), throwsArgumentError);
      expect(() => sanitizeHfDirName('///'), throwsArgumentError);
    });
  });
}
