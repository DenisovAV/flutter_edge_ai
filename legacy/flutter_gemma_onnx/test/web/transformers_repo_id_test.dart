// Pure-Dart unit test for the ONNX web text-generation repo-id mapping. This
// runs on the VM (`flutter test`) BECAUSE `transformers_repo_id.dart` was
// split out of `TransformersWebResolver` specifically to have no web-only
// imports (the resolver itself transitively imports `dart:js_interop` via
// `WebModelManager` and can only be compile-checked by `flutter build web`).
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma_onnx/src/web/transformers_repo_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transformersRepoIdFromSource', () {
    test('NetworkSource HF repo URL -> owner/name', () {
      expect(
        transformersRepoIdFromSource(
          NetworkSource('https://huggingface.co/onnx-community/Qwen2.5-0.5B'),
        ),
        'onnx-community/Qwen2.5-0.5B',
      );
    });

    test(
      'NetworkSource HF URL ignores any path/query suffix past owner/name',
      () {
        expect(
          transformersRepoIdFromSource(
            NetworkSource(
              'https://huggingface.co/onnx-community/Qwen2.5-0.5B/tree/main?x=1',
            ),
          ),
          'onnx-community/Qwen2.5-0.5B',
        );
      },
    );

    test('BundledSource -> resourceName verbatim (self-hosted flat id)', () {
      // BundledSource forbids '/' in resourceName, so a self-hosted id is a
      // single flat segment (resolved under Transformers.js env.localModelPath).
      expect(
        transformersRepoIdFromSource(BundledSource('local-model-x')),
        'local-model-x',
      );
    });

    test('non-HuggingFace NetworkSource URL throws ArgumentError', () {
      expect(
        () => transformersRepoIdFromSource(
          NetworkSource('https://example.com/onnx-community/Qwen2.5-0.5B'),
        ),
        throwsArgumentError,
      );
    });

    test('HF URL with fewer than two path segments throws ArgumentError', () {
      expect(
        () => transformersRepoIdFromSource(
          NetworkSource('https://huggingface.co/onnx-community'),
        ),
        throwsArgumentError,
      );
    });

    test('AssetSource is not a valid repo identity (UnsupportedError)', () {
      expect(
        () => transformersRepoIdFromSource(AssetSource('models/x.onnx')),
        throwsUnsupportedError,
      );
    });

    test('FileSource is not a valid repo identity (UnsupportedError)', () {
      expect(
        () => transformersRepoIdFromSource(FileSource('/tmp/x.onnx')),
        throwsUnsupportedError,
      );
    });
  });
}
