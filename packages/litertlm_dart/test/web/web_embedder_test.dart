// LiteRtLmWebEmbedder (the EmbeddingGemma 2 web embedder) on the VM, over a
// fake runtime: what reaches EmbeddingEngine.create, the probe and the input
// limit it pins, the container-header refusals before any engine exists, the
// typed overflow, and that every load that fails — or is closed while it
// runs — deletes the engine it created, and that work queued behind a close
// never reaches the runtime. flutter_edge_ai_litertlm's
// test/litert_lm_web_embedding_pass_test.dart drives the same embedder
// through core's pass and words.
@TestOn('vm')
library;

import 'dart:async';

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

import 'web_embedder_fakes.dart';

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a text load: GPU, maxInputLength 1024, no towers; the dimension and '
      'the window pinned at 1024/1025 tokens', () async {
    final runtime = FakeWebRuntime();
    final info = await fakeEmbedder(runtime).load();
    final s = runtime.settings.single;
    expect(s.backend, LiteRtLmWebBackend.gpu);
    expect(s.maxInputLength, 1024);
    expect(s.visionBackend, isNull);
    expect(s.audioBackend, isNull);
    expect(info.dimension, 4);
    expect(info.maxInputTokens, 1024);
    expect(info.modalities, {EmbedderModality.text});
  });

  for (final (what, arrange, reason) in [
    (
      'the probe throws',
      (FakeWebRuntime r) => r.probeError = StateError('trap'),
      'could not embed with it',
    ),
    (
      'the probe is all zeros',
      (FakeWebRuntime r) => r.vector = const [0, 0, 0, 0],
      'NaN, infinity or only zeros',
    ),
    (
      'the probe has a NaN',
      (FakeWebRuntime r) => r.vector = [double.nan, 1, 1, 1],
      'NaN, infinity or only zeros',
    ),
    (
      'the probe is empty',
      (FakeWebRuntime r) => r.vector = const [],
      'empty vector',
    ),
  ]) {
    test(
      '$what: the load fails, and the engine it created is deleted',
      () async {
        final runtime = FakeWebRuntime();
        arrange(runtime);
        final embedder = fakeEmbedder(runtime);
        await expectLater(
          embedder.load(),
          throwsA(
            isA<EmbedderLoadException>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
        );
        expect(runtime.created.single.deletes, 1);
        await expectLater(
          embedder.embed(EmbedderInput(text: 'x')),
          throwsA(
            isA<EmbedderEngineException>().having(
              (e) => e.message,
              'message',
              contains('needs a loaded, open embedder'),
            ),
          ),
        );
      },
    );
  }

  test(
    'closed while it loads: the load fails, the engine is deleted once',
    () async {
      final runtime = FakeWebRuntime()..createGate = Completer<void>();
      final embedder = fakeEmbedder(runtime);
      final loading = embedder.load();
      await _settle();
      final closing = embedder.close();
      runtime.createGate!.complete();
      await expectLater(
        loading,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is closed'),
          ),
        ),
      );
      await closing;
      expect(runtime.created.single.deletes, 1);
      expect(runtime.created.single.computes, 0, reason: 'probed a closed one');
    },
  );

  test('images on the 270m and audio on the 440m are refused from the '
      'container header, naming the bundle that has the tower, before any '
      'engine exists', () async {
    final vision = FakeWebRuntime()..file = eg2Header('270m');
    await expectLater(
      fakeEmbedder(vision, media: {EmbedderModality.image}).load(),
      throwsA(
        isA<EmbedderLoadException>().having(
          (e) => e.message,
          'message',
          contains('embeddinggemma-2-text-vision-440m'),
        ),
      ),
    );
    expect(vision.created, isEmpty);
    final audio = FakeWebRuntime()..file = eg2Header('440m');
    await expectLater(
      fakeEmbedder(audio, media: {EmbedderModality.audio}).load(),
      throwsA(
        isA<EmbedderLoadException>().having(
          (e) => e.message,
          'message',
          contains(liteRtLmAudioBundle),
        ),
      ),
    );
    expect(audio.created, isEmpty);
  });

  test('images and audio on the 740m: both towers, on WebGPU', () async {
    final runtime = FakeWebRuntime();
    final info = await fakeEmbedder(
      runtime,
      media: {EmbedderModality.image, EmbedderModality.audio},
    ).load();
    expect(runtime.settings.single.visionBackend, LiteRtLmWebBackend.gpu);
    expect(runtime.settings.single.audioBackend, LiteRtLmWebBackend.gpu);
    expect(info.modalities, EmbedderModality.values.toSet());
  });

  test('an input the engine splits is EmbedderInputTooLongException with its '
      'exact count; the vector is never returned', () async {
    final runtime = FakeWebRuntime();
    final embedder = fakeEmbedder(runtime);
    await embedder.load();
    await expectLater(
      embedder.embed(EmbedderInput(text: 'w' * 1023)),
      throwsA(
        isA<EmbedderInputTooLongException>()
            .having((e) => e.maxInputTokens, 'max', 1024)
            .having((e) => e.actualTokens, 'actual', 1025),
      ),
    );
    expect(await embedder.embed(EmbedderInput(text: 'w' * 1022)), hasLength(4));
  });

  test('an embed queued on the page lock when the embedder closes never '
      'reaches the runtime', () async {
    final runtime = FakeWebRuntime();
    final embedder = fakeEmbedder(runtime);
    await embedder.load();
    final engine = runtime.created.single;
    final before = engine.computes;
    final held = await liteRtLmPageLock.acquire();
    final queued = embedder.embed(EmbedderInput(text: 'x'));
    final expectation = expectLater(
      queued,
      throwsA(
        isA<EmbedderEngineException>().having(
          (e) => e.message,
          'message',
          allOf(contains('could not embed the text'), contains('is closed')),
        ),
      ),
    );
    await _settle();
    await embedder.close();
    held.release();
    await expectation;
    expect(engine.computes, before);
    expect(engine.deletes, 1);
  });
}
