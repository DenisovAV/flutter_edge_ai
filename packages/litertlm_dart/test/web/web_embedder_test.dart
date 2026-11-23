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
import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

Uint8List _header(String bundle) => File(
  'test/ffi/fixtures/embeddinggemma2_${bundle}_header.litertlm',
).readAsBytesSync();

int _tokens(LiteRtLmWebInput input) => switch (input) {
  LiteRtLmWebText(:final text) =>
    RegExp(r'^the( the)*$').hasMatch(text)
        ? text.split(' ').length
        : text.length,
  LiteRtLmWebImage() => 140,
  LiteRtLmWebAudio(:final bytes) => bytes.length,
  LiteRtLmWebParts(:final parts) => parts.fold(0, (n, p) => n + _tokens(p)),
};

final class _Engine implements LiteRtLmWebEngine {
  _Engine(this.runtime);

  final _Runtime runtime;
  int computes = 0;
  int deletes = 0;

  @override
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  ) async {
    computes++;
    if (runtime.probeError case final error? when computes == 1) throw error;
    final tokens = _tokens(input) + 2;
    final vector = runtime.vector;
    // WebGPU: windows of 1024, averaged, whatever the strategy.
    return (
      embedding: vector,
      inputLength: tokens,
      truncatedLength: null,
      numChunks: (tokens + 1023) ~/ 1024,
    );
  }

  @override
  Future<void> delete() async => deletes++;
}

final class _Runtime implements LiteRtLmWebRuntime {
  Uint8List file = _header('740m');
  List<double> vector = const [0.5, 0.5, 0.5, 0.5];
  Object? probeError;
  Completer<void>? createGate;
  final created = <_Engine>[];
  final settings = <LiteRtLmWebEngineSettings>[];

  @override
  Future<LiteRtLmWebRuntimeState> ensureReady() async =>
      LiteRtLmWebRuntimeState.ready;

  @override
  Future<LiteRtLmWebGpuSupport> webGpuSupport() async =>
      LiteRtLmWebGpuSupport.available;

  @override
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings s) async {
    settings.add(s);
    await createGate?.future;
    final engine = _Engine(this);
    created.add(engine);
    return engine;
  }

  @override
  Future<Uint8List> readPrefix(String url, int length) async =>
      Uint8List.sublistView(file, 0, length.clamp(0, file.length));
}

LiteRtLmWebEmbedder _embedder(
  _Runtime runtime, {
  Set<EmbedderModality> media = const {},
  String file = 'embeddinggemma-2-740m.litertlm',
}) => LiteRtLmWebEmbedder(
  LiteRtLmWebEmbedderConfig(
    modelPath: 'blob:eg2',
    fileName: file,
    runtime: runtime,
    resolveUrl: (path) async => path,
    revokeUrl: (_) {},
    declaredMedia: media,
  ),
);

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a text load: GPU, maxInputLength 1024, no towers; the dimension and '
      'the window pinned at 1024/1025 tokens', () async {
    final runtime = _Runtime();
    final info = await _embedder(runtime).load();
    final s = runtime.settings.single;
    expect(s.backend, LiteRtLmWebBackend.gpu);
    expect(s.maxInputLength, 1024);
    expect(s.visionBackend, isNull);
    expect(s.audioBackend, isNull);
    expect(info.dimension, 4);
    expect(info.maxInputTokens, 1024);
    expect(info.modalities, {EmbedderModality.text});
  });

  for (final (what, arrange) in [
    ('the probe throws', (_Runtime r) => r.probeError = StateError('trap')),
    ('the probe is all zeros', (_Runtime r) => r.vector = const [0, 0, 0, 0]),
    ('the probe has a NaN', (_Runtime r) => r.vector = [double.nan, 1, 1, 1]),
    ('the probe is empty', (_Runtime r) => r.vector = const []),
  ]) {
    test(
      '$what: the load fails, and the engine it created is deleted',
      () async {
        final runtime = _Runtime();
        arrange(runtime);
        final embedder = _embedder(runtime);
        await expectLater(
          embedder.load(),
          throwsA(isA<EmbedderLoadException>()),
        );
        expect(runtime.created.single.deletes, 1);
        await expectLater(
          embedder.embed(EmbedderInput(text: 'x')),
          throwsA(isA<EmbedderEngineException>()),
        );
      },
    );
  }

  test(
    'closed while it loads: the load fails, the engine is deleted once',
    () async {
      final runtime = _Runtime()..createGate = Completer<void>();
      final embedder = _embedder(runtime);
      final loading = embedder.load();
      await _settle();
      final closing = embedder.close();
      runtime.createGate!.complete();
      await expectLater(loading, throwsStateError);
      await closing;
      expect(runtime.created.single.deletes, 1);
      expect(runtime.created.single.computes, 0, reason: 'probed a closed one');
    },
  );

  test('images on the 270m and audio on the 440m are refused from the '
      'container header, naming the bundle that has the tower, before any '
      'engine exists', () async {
    final vision = _Runtime()..file = _header('270m');
    await expectLater(
      _embedder(vision, media: {EmbedderModality.image}).load(),
      throwsA(
        isA<EmbedderLoadException>().having(
          (e) => e.message,
          'message',
          contains('embeddinggemma-2-text-vision-440m'),
        ),
      ),
    );
    expect(vision.created, isEmpty);
    final audio = _Runtime()..file = _header('440m');
    await expectLater(
      _embedder(audio, media: {EmbedderModality.audio}).load(),
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
    final runtime = _Runtime();
    final info = await _embedder(
      runtime,
      media: {EmbedderModality.image, EmbedderModality.audio},
    ).load();
    expect(runtime.settings.single.visionBackend, LiteRtLmWebBackend.gpu);
    expect(runtime.settings.single.audioBackend, LiteRtLmWebBackend.gpu);
    expect(info.modalities, EmbedderModality.values.toSet());
  });

  test('an input the engine splits is EmbedderInputTooLongException with its '
      'exact count; the vector is never returned', () async {
    final runtime = _Runtime();
    final embedder = _embedder(runtime);
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
    final runtime = _Runtime();
    final embedder = _embedder(runtime);
    await embedder.load();
    final engine = runtime.created.single;
    final before = engine.computes;
    final held = await liteRtLmPageLock.acquire();
    final queued = embedder.embed(EmbedderInput(text: 'x'));
    final expectation = expectLater(
      queued,
      throwsA(isA<EmbedderEngineException>()),
    );
    await _settle();
    await embedder.close();
    held.release();
    await expectation;
    expect(engine.computes, before);
    expect(engine.deletes, 1);
  });
}
