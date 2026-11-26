// The web embedder's per-request EmbeddingOptions (Kotlin's and Swift's) and
// its maxInputLength, on the VM over the fake runtime: what reaches
// computeEmbedding, the vector size an outputSize asks for, the vision budget
// the web runtime cannot change per request, and the window pinned for a
// maxInputLength other than 1024.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:litertlm_dart/internal.dart';
import 'package:litertlm_dart/litertlm_dart.dart' show EmbeddingOptions;
import 'package:test/test.dart';

import 'web_embedder_fakes.dart';

void main() {
  test(
    'no options: normalised, special tokens on, TRUNCATE, nothing else',
    () async {
      final runtime = FakeWebRuntime();
      final embedder = fakeEmbedder(runtime);
      await embedder.load();
      await embedder.embed(EmbedderInput(text: 'hello'));
      final sent = runtime.options.last;
      expect(sent.normalize, isTrue);
      expect(sent.insertSpecialTokens, isTrue);
      expect(sent.outputSize, isNull);
      expect(sent.visionTokensPerImage, isNull);
    },
  );

  test('outputSize, normalize and insertSpecialTokens reach the runtime; the '
      'vector is outputSize long', () async {
    final runtime = FakeWebRuntime();
    final embedder = fakeEmbedder(runtime);
    await embedder.load();
    final v = await embedder.embed(
      EmbedderInput(text: 'hello'),
      options: const EmbeddingOptions(
        outputSize: 2,
        normalize: false,
        insertSpecialTokens: false,
      ),
    );
    expect(v, hasLength(2));
    final sent = runtime.options.last;
    expect(sent.outputSize, 2);
    expect(sent.normalize, isFalse);
    expect(sent.insertSpecialTokens, isFalse);
    expect(sent.inputOverflowStrategy, LiteRtLmWebOverflowStrategy.truncate);
  });

  test('an outputSize outside 1..dimension, or a vision budget other than the '
      "engine's, is refused before the runtime", () async {
    final runtime = FakeWebRuntime();
    final embedder = fakeEmbedder(runtime, media: {EmbedderModality.image});
    await embedder.load();
    final before = runtime.options.length;
    for (final options in const [
      EmbeddingOptions(outputSize: 0),
      EmbeddingOptions(outputSize: 5),
      EmbeddingOptions(visionTokensPerImage: 70),
    ]) {
      await expectLater(
        embedder.embed(
          EmbedderInput(
            images: [
              Uint8List.fromList([1]),
            ],
          ),
          options: options,
        ),
        throwsArgumentError,
      );
    }
    expect(runtime.options, hasLength(before));
    await embedder.embed(
      EmbedderInput(
        images: [
          Uint8List.fromList([1]),
        ],
      ),
      options: const EmbeddingOptions(visionTokensPerImage: 140),
    );
    expect(runtime.options.last.visionTokensPerImage, 140);
  });

  test('maxInputLength 300: sent to create, and the 512-token window is '
      'pinned as the limit', () async {
    final runtime = FakeWebRuntime()..window = 512;
    final info = await fakeEmbedder(runtime, maxInputLength: 300).load();
    expect(runtime.settings.single.maxInputLength, 300);
    expect(info.maxInputTokens, 512);
  });
}
