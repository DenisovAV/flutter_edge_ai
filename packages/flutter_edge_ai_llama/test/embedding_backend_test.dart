import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_edge_ai_llama/src/llama_embedding_backend.dart'
    show createLlamaEmbeddingBackendForTest;
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

EmbeddingModelSpec _spec(String filename) => EmbeddingModelSpec(
  name: 'embedding',
  modelSource: ModelSource.network('https://models.test/$filename'),
);
RuntimeConfig _config({
  PreferredBackend? backend,
  bool image = false,
  bool audio = false,
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: '/models/eg2.gguf',
  preferredBackend: backend,
  supportImage: image,
  supportAudio: audio,
);

void main() {
  test(
    'claims self-contained GGUF on native only and preserves request keys',
    () {
      const backend = LlamaEmbeddingBackend();
      expect(backend.canHandle(_spec('eg2.GGUF')), !kIsWeb);
      expect(backend.canHandle(_spec('eg2.litertlm')), isFalse);
      for (final request in [null, ...PreferredBackend.values]) {
        expect(backend.cacheBackend(request), request);
      }
    },
  );

  test('refuses unsupported configuration without loading a runtime', () async {
    final backend = createLlamaEmbeddingBackendForTest(
      loader: (_, _) async => fail('must not load'),
    );
    for (final config in [
      _config(image: true),
      _config(audio: true),
      _config(backend: PreferredBackend.npu),
    ]) {
      await expectLater(
        backend.describe(_spec('eg2.gguf'), config),
        throwsA(isA<EmbeddingLoadException>()),
      );
    }
  });

  test('Web is explicitly refused before constructing a pass', () async {
    await expectLater(
      const LlamaEmbeddingBackend().describe(_spec('eg2.gguf'), _config()),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'reason',
          contains('native'),
        ),
      ),
    );
  }, skip: !kIsWeb);

  group('native embedding pass', () {
    late _Engine engine;
    late LlamaEmbeddingBackend backend;
    setUp(() {
      engine = _Engine();
      backend = createLlamaEmbeddingBackendForTest(
        loader: (_, params) async {
          expect(params.contextSize, 1024);
          expect(params.batchSize, 1024);
          expect(params.microBatchSize, 1024);
          expect(params.maxParallelSequences, 1);
          return engine;
        },
      );
    });

    Future<EmbeddingPass> pass({PreferredBackend? request}) async {
      final descriptor = await backend.describe(
        _spec('eg2.gguf'),
        _config(backend: request),
      );
      expect(descriptor.activeBackend, isNull);
      final pass = descriptor.build();
      addTearDown(pass.close);
      return pass;
    }

    test('reports output projection dimension and loaded backend', () async {
      engine.backendName = 'Metal';
      final p = await pass(request: PreferredBackend.gpu);
      final info = await p.load();
      expect(info.dimension, 2);
      expect(info.maxInputTokens, 1024);
      expect(info.modalities, {EmbeddingModality.text});
      expect(info.activeBackend, PreferredBackend.gpu);
      for (final task in TaskType.values) {
        expect(await p.embed(EmbeddingInput.text('text'), task), [1.0, 0.0]);
        expect(engine.inputs.last, '${task.prefix}text');
      }
      await p.close();
      await p.close();
      expect(engine.disposals, 1);
    });

    test('unknown runtime accelerator stays unknown', () async {
      engine.backendName = 'unreported';
      expect((await (await pass()).load()).activeBackend, isNull);
    });

    test('explicit GPU does not silently return CPU', () async {
      await expectLater(
        (await pass(request: PreferredBackend.gpu)).load(),
        throwsUnsupportedError,
      );
    });

    test(
      'overflow maps exact fields; arbitrary errors stay engine failures',
      () async {
        final p = await pass();
        await p.load();
        engine.failure = llama.LlamaEmbeddingInputTooLongException(
          'overflow',
          maxInputTokens: 1024,
          actualTokens: 1027,
        );
        await expectLater(
          p.embed(EmbeddingInput.text('large'), TaskType.none),
          throwsA(
            isA<EmbeddingInputTooLongException>()
                .having((e) => e.maxInputTokens, 'limit', 1024)
                .having((e) => e.actualTokens, 'count', 1027),
          ),
        );
        engine.failure = llama.LlamaInferenceException(
          'input overflow words are not a contract',
        );
        await expectLater(
          p.embed(EmbeddingInput.text('text'), TaskType.none),
          throwsA(isA<EmbeddingEngineException>()),
        );
        engine.failure = null;
        expect(await p.embed(EmbeddingInput.text('short'), TaskType.none), [
          1,
          0,
        ]);
      },
    );

    for (final scenario in [
      'architecture',
      'pooling',
      'capability',
      'context',
      'dimension',
      'zero',
    ]) {
      test('refuses unqualified $scenario and closes its runtime', () async {
        switch (scenario) {
          case 'architecture':
            engine.metadata['general.architecture'] = 'bert';
          case 'pooling':
            engine.metadata['gemma-embedding2.pooling_type'] = '3';
          case 'capability':
            engine.supported = false;
          case 'context':
            engine.context = 512;
          case 'dimension':
            engine.metadata['gemma-embedding2.embedding_length_out'] = '512';
          case 'zero':
            engine.vector = [0, 0];
        }
        final p = await pass();
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        await p.close();
        expect(engine.disposals, 1);
      });
    }
  }, skip: kIsWeb);
}

final class _Engine extends llama.LlamaEngine {
  _Engine() : super(llama.LlamaBackend());
  final metadata = <String, String>{
    'general.architecture': 'gemma-embedding2',
    'gemma-embedding2.pooling_type': '1',
    'gemma-embedding2.embedding_length': '512',
    'gemma-embedding2.embedding_length_out': '2',
  };
  String backendName = 'CPU';
  bool supported = true;
  int context = 1024;
  int disposals = 0;
  Object? failure;
  List<double> vector = [1, 0];
  final inputs = <String>[];
  @override
  llama.LlamaRuntime? get runtime => llama.LlamaRuntime.llamaCpp;
  @override
  Future<Map<String, String>> getMetadata() async => metadata;
  @override
  Future<llama.LlamaEmbeddingCapabilities> get embeddingCapabilities async =>
      llama.LlamaEmbeddingCapabilities(text: supported);
  @override
  Future<int> getContextSize() async => context;
  @override
  Future<String> getBackendName() async => backendName;
  @override
  Future<List<double>> embed(String text, {bool normalize = true}) async {
    expect(normalize, isTrue);
    inputs.add(text);
    if (failure case final error?) throw error;
    return vector;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}
