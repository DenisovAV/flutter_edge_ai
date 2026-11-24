// The fake @litert-lm/core embedding runtime the VM suites drive the web
// embedder with: a WebGPU-like engine that splits an over-long input into
// windows of 1024 tokens, and a runtime whose create can be held.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/internal.dart';

Uint8List eg2Header(String bundle) => File(
  'test/ffi/fixtures/embeddinggemma2_${bundle}_header.litertlm',
).readAsBytesSync();

int fakeTokens(LiteRtLmWebInput input) => switch (input) {
  LiteRtLmWebText(:final text) =>
    RegExp(r'^the( the)*$').hasMatch(text)
        ? text.split(' ').length
        : text.length,
  LiteRtLmWebImage() => 140,
  LiteRtLmWebAudio(:final bytes) => bytes.length,
  LiteRtLmWebParts(:final parts) => parts.fold(0, (n, p) => n + fakeTokens(p)),
};

final class FakeWebEngine implements LiteRtLmWebEngine {
  FakeWebEngine(this.runtime);

  final FakeWebRuntime runtime;
  int computes = 0;
  int deletes = 0;

  @override
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  ) async {
    computes++;
    if (runtime.probeError case final error? when computes == 1) throw error;
    final tokens = fakeTokens(input) + 2;
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

final class FakeWebRuntime implements LiteRtLmWebRuntime {
  Uint8List file = eg2Header('740m');
  List<double> vector = const [0.5, 0.5, 0.5, 0.5];
  Object? probeError;
  Completer<void>? createGate;
  final created = <FakeWebEngine>[];
  final settings = <LiteRtLmWebEngineSettings>[];

  @override
  Future<LiteRtLmWebRuntimeState> ensureReady() async =>
      LiteRtLmWebRuntimeState.ready;

  @override
  List<String> get missingMembers => const [];

  @override
  Future<LiteRtLmWebGpuSupport> webGpuSupport() async =>
      LiteRtLmWebGpuSupport.available;

  @override
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings s) async {
    settings.add(s);
    await createGate?.future;
    final engine = FakeWebEngine(this);
    created.add(engine);
    return engine;
  }

  @override
  Future<Uint8List> readPrefix(String url, int length) async =>
      Uint8List.sublistView(file, 0, length.clamp(0, file.length));
}

LiteRtLmWebEmbedder fakeEmbedder(
  FakeWebRuntime runtime, {
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
