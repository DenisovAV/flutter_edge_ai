import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/test_helpers.dart';

/// Guards against the class of bug Google flagged: a model whose URL/filename
/// is `.litertlm` but whose declared `ModelFileType` is `.task` (or vice
/// versa). Engine routing is driven by the declared `fileType` (`.task` →
/// MediaPipe, `.litertlm` → LiteRT-LM), so a fileType that disagrees with the
/// actual file extension routes the model to the wrong engine — a `.litertlm`
/// file sent to MediaPipe won't load.
///
/// This is a PURE test (no network, no device) — it validates the static
/// `TestModelConfig` values, so it runs under `flutter test` without a target.
void main() {
  /// The fileType every model file with [extension] must declare, per
  /// flutter_gemma's `ModelFileType` doc comments (core/model.dart):
  ///   .task            → ModelFileType.task     (MediaPipe)
  ///   .bin / .tflite   → ModelFileType.binary   (manual templates)
  ///   .litertlm        → ModelFileType.litertlm (LiteRT-LM)
  ModelFileType expectedFileType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.litertlm')) return ModelFileType.litertlm;
    if (lower.endsWith('.task')) return ModelFileType.task;
    if (lower.endsWith('.bin') || lower.endsWith('.tflite')) {
      return ModelFileType.binary;
    }
    fail('Unrecognised model extension in "$path" — extend expectedFileType.');
  }

  void checkConsistent(String label, TestModelConfig config) {
    // The URL extension and the filename extension must agree with each other…
    expect(
      expectedFileType(config.url),
      expectedFileType(config.filename),
      reason:
          '$label: url "${config.url}" and filename "${config.filename}" '
          'have mismatched extensions',
    );
    // …and the declared fileType must match that extension, so the engine
    // registry routes the file to the engine that can actually load it.
    expect(
      config.fileType,
      expectedFileType(config.url),
      reason:
          '$label: declares fileType ${config.fileType} but the model file '
          '"${config.url}" is a ${expectedFileType(config.url)} file — this '
          'routes to the wrong inference engine (the bug Google reported).',
    );
  }

  test('mediapipeConfig fileType matches its .task file', () {
    checkConsistent('mediapipeConfig', TestModelConfig.mediapipeConfig);
    expect(TestModelConfig.mediapipeConfig.fileType, ModelFileType.task);
  });

  test('litertlmConfig fileType matches its .litertlm file', () {
    checkConsistent('litertlmConfig', TestModelConfig.litertlmConfig);
    // The regression: this was ModelFileType.task, routing the .litertlm model
    // to MediaPipe. It must be ModelFileType.litertlm.
    expect(TestModelConfig.litertlmConfig.fileType, ModelFileType.litertlm);
  });

  test('every allForCurrentPlatform() config is fileType-consistent', () {
    final configs = TestModelConfig.allForCurrentPlatform();
    expect(configs, isNotEmpty);
    for (final entry in configs) {
      checkConsistent(entry.label, entry.config);
    }
  });

  test('forCurrentPlatform() is fileType-consistent', () {
    checkConsistent('forCurrentPlatform', TestModelConfig.forCurrentPlatform());
  });
}
