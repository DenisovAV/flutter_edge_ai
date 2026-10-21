import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — verifies actual embedding registry selection without changing the public SPI.
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
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
  String modelPath = '/models/eg2.gguf',
  String? tokenizerPath,
}) => RuntimeConfig(
  maxTokens: 0,
  modelPath: modelPath,
  tokenizerPath: tokenizerPath,
  preferredBackend: backend,
  supportImage: image,
  supportAudio: audio,
);

void main() {
  test(
    'claims self-contained GGUF and declares native CPU/GPU capabilities',
    () {
      const backend = LlamaEmbeddingBackend();
      expect(backend.canHandle(_spec('eg2.GGUF')), !kIsWeb);
      expect(backend.canHandle(_spec('eg2.litertlm')), isFalse);
      expect(
        backend.canHandle(
          EmbeddingModelSpec(
            name: 'opaque download',
            modelSource: ModelSource.network(
              'https://models.test/download?id=123',
            ),
            modelFilename: 'eg2.GGUF',
          ),
        ),
        !kIsWeb,
      );
      expect(
        backend.canHandle(
          EmbeddingModelSpec(
            name: 'separate tokenizer',
            modelSource: ModelSource.network('https://models.test/model.onnx'),
            tokenizerSource: ModelSource.network(
              'https://models.test/tokenizer.json',
            ),
          ),
        ),
        isFalse,
      );
      expect(
        backend.honouredBackends(_spec('eg2.gguf')),
        kIsWeb ? isEmpty : {PreferredBackend.cpu, PreferredBackend.gpu},
      );
      expect(backend.backendFallback, isTrue);
    },
  );

  test('registry selects GGUF over a generic fallback in either order', () {
    final registry = EmbeddingRegistry.instance;
    registry.reset();
    addTearDown(registry.reset);
    const llamaBackend = LlamaEmbeddingBackend();
    const fallback = _GenericFallbackBackend();
    for (final providers in [
      [fallback, llamaBackend],
      [llamaBackend, fallback],
    ]) {
      registry.reset();
      registry.registerAll(providers);
      expect(registry.findFor(_spec('eg2.GGUF')), same(llamaBackend));
      expect(registry.findFor(_spec('eg2.litertlm')), same(fallback));
    }
  }, skip: kIsWeb);

  test('refuses unsupported configuration without loading a runtime', () async {
    final backend = createLlamaEmbeddingBackendForTest(
      loader: (_, _) async => fail('must not load'),
    );
    for (final config in [
      _config(image: true),
      _config(audio: true),
      _config(backend: PreferredBackend.npu),
      _config(tokenizerPath: '/models/tokenizer.json'),
      _config(modelPath: ''),
      _config(modelPath: 'opfs://eg2.gguf'),
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
    late int loadAttempts;
    setUp(() {
      engine = _Engine();
      loadAttempts = 0;
      backend = createLlamaEmbeddingBackendForTest(
        loader: (path, params) async {
          loadAttempts++;
          expect(path, '/models/eg2.gguf');
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

    test(
      'unknown runtime accelerator fails instead of guessing placement',
      () async {
        engine.backendName = 'unreported';
        await expectLater(
          (await pass()).load(),
          throwsA(isA<EmbeddingLoadException>()),
        );
      },
    );

    test('default GPU fallback reports the loaded CPU', () async {
      expect(
        (await (await pass(
          request: PreferredBackend.gpu,
        )).load()).activeBackend,
        PreferredBackend.cpu,
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

    test(
      'strict GPU mismatch fails as a load exception and closes once',
      () async {
        final strict = createLlamaEmbeddingBackendForTest(
          loader: (_, _) async => engine,
          backendFallback: false,
        );
        final p = (await strict.describe(
          _spec('eg2.gguf'),
          _config(backend: PreferredBackend.gpu),
        )).build();
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        await p.close();
        expect(engine.disposals, 1);
      },
    );

    for (final placement in [
      (
        request: PreferredBackend.cpu,
        loaded: 'CPU',
        active: PreferredBackend.cpu,
      ),
      (
        request: PreferredBackend.gpu,
        loaded: 'Metal',
        active: PreferredBackend.gpu,
      ),
      (request: null, loaded: 'CPU', active: PreferredBackend.cpu),
      (request: null, loaded: 'Metal', active: PreferredBackend.gpu),
    ]) {
      test(
        'strict ${placement.request?.name ?? "auto"} accepts ${placement.loaded}',
        () async {
          engine.backendName = placement.loaded;
          var attempts = 0;
          final strict = createLlamaEmbeddingBackendForTest(
            backendFallback: false,
            loader: (path, _) async {
              expect(path, '/models/strict embedding.gguf');
              attempts++;
              return engine;
            },
          );
          final p = (await strict.describe(
            _spec('eg2.gguf'),
            _config(
              backend: placement.request,
              modelPath: '/models/strict embedding.gguf',
            ),
          )).build();
          addTearDown(p.close);
          expect((await p.load()).activeBackend, placement.active);
          expect(attempts, 1);
          expect(await p.embed(EmbeddingInput.text('valid'), TaskType.none), [
            1,
            0,
          ]);
        },
      );
    }

    for (final request in [null, PreferredBackend.gpu, PreferredBackend.cpu]) {
      for (final fallback in [false, true]) {
        for (final cause in [
          llama.LlamaUnsupportedException('backend unavailable'),
          llama.LlamaBackendInitializationException('backend unavailable'),
          llama.LlamaContextException('context unavailable'),
          TimeoutException('worker initialization timed out'),
        ]) {
          test(
            '${request?.name ?? "auto"}, fallback=$fallback, '
            '${cause.runtimeType}: retry policy and warning ordering',
            () async {
              final events = <String>[];
              final paramsSeen = <llama.ModelParams>[];
              final messages = <String>[];
              final retries =
                  fallback &&
                  request == PreferredBackend.gpu &&
                  cause is llama.LlamaUnsupportedException;
              final candidate = createLlamaEmbeddingBackendForTest(
                backendFallback: fallback,
                loader: (path, params) async {
                  expect(path, '/models/installed embedding.gguf');
                  expect(params.contextSize, 1024);
                  expect(params.batchSize, 1024);
                  expect(params.microBatchSize, 1024);
                  expect(params.maxParallelSequences, 1);
                  paramsSeen.add(params);
                  if (paramsSeen.length == 1) {
                    events.add('load');
                    await Future<void>.delayed(Duration.zero);
                    events.add('cleanup'); // atomic SDK loader contract
                    throw cause;
                  }
                  events.add('retry');
                  expect(events, ['load', 'cleanup', 'warning', 'retry']);
                  expect(params.device, llama.ComputeDevice.cpu);
                  expect(params.gpuLayers, 0);
                  return engine;
                },
              );
              final p = (await candidate.describe(
                _spec('eg2.gguf'),
                _config(
                  backend: request,
                  modelPath: '/models/installed embedding.gguf',
                ),
              )).build();
              await runZoned(
                () async {
                  if (retries) {
                    expect(
                      (await p.load()).activeBackend,
                      PreferredBackend.cpu,
                    );
                  } else {
                    await expectLater(
                      p.load(),
                      throwsA(
                        isA<EmbeddingLoadException>().having(
                          (e) => e.cause,
                          'cause',
                          same(cause),
                        ),
                      ),
                    );
                  }
                },
                zoneSpecification: ZoneSpecification(
                  print: (_, _, _, message) {
                    messages.add(message);
                    events.add('warning');
                  },
                ),
              );
              expect(paramsSeen.length, retries ? 2 : 1);
              expect(paramsSeen.first.device, switch (request) {
                PreferredBackend.cpu => llama.ComputeDevice.cpu,
                PreferredBackend.gpu => llama.ComputeDevice.gpu,
                _ => llama.ComputeDevice.auto,
              });
              expect(
                paramsSeen.first.gpuLayers,
                request == PreferredBackend.cpu
                    ? 0
                    : llama.ModelParams.maxGpuLayers,
              );
              if (retries) {
                expect(messages, hasLength(1));
                expect(messages.single, contains('WARNING: GPU'));
                expect(
                  messages.single,
                  allOf(
                    contains(cause.toString()),
                    contains('retrying on CPU'),
                  ),
                );
              } else {
                expect(messages, isEmpty);
              }
              await p.close();
            },
          );
        }
      }
    }

    for (final fallback in [false, true]) {
      test('guard refuses GPU before loader; fallback=$fallback', () async {
        final paramsSeen = <llama.ModelParams>[];
        var guards = 0;
        final candidate = createLlamaEmbeddingBackendForTest(
          backendFallback: fallback,
          gpuRefusal: () {
            guards++;
            return 'guarded platform';
          },
          loader: (path, params) async {
            expect(path, '/models/eg2.gguf');
            paramsSeen.add(params);
            expect(params.device, llama.ComputeDevice.cpu);
            expect(params.gpuLayers, 0);
            expect(params.contextSize, 1024);
            expect(params.batchSize, 1024);
            expect(params.microBatchSize, 1024);
            expect(params.maxParallelSequences, 1);
            return engine;
          },
        );
        final p = (await candidate.describe(
          _spec('eg2.gguf'),
          _config(backend: PreferredBackend.gpu),
        )).build();
        addTearDown(p.close);
        if (fallback) {
          expect((await p.load()).activeBackend, PreferredBackend.cpu);
        } else {
          await expectLater(
            p.load(),
            throwsA(
              isA<EmbeddingLoadException>().having(
                (e) => e.cause,
                'guard error',
                isA<llama.LlamaUnsupportedException>(),
              ),
            ),
          );
        }
        expect(guards, 1);
        expect(paramsSeen, hasLength(fallback ? 1 : 0));
      });
    }

    Future<List<String>> autoLoadMessages(
      String? refusal, {
      String backendName = 'CPU',
      PreferredBackend expected = PreferredBackend.cpu,
    }) async {
      engine.backendName = backendName;
      final messages = <String>[];
      final candidate = createLlamaEmbeddingBackendForTest(
        gpuRefusal: () => refusal,
        loader: (path, params) async {
          expect(params.device, llama.ComputeDevice.auto);
          expect(params.gpuLayers, greaterThan(0));
          return engine;
        },
      );
      final p = (await candidate.describe(
        _spec('eg2.gguf'),
        _config(),
      )).build();
      addTearDown(p.close);
      await runZoned(
        () async => expect((await p.load()).activeBackend, expected),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, message) => messages.add(message),
        ),
      );
      return messages;
    }

    test('successful automatic CPU selection warns once', () async {
      final messages = await autoLoadMessages(null);
      expect(messages, hasLength(1));
      expect(
        messages.single,
        contains('requested GPU layers but selected CPU'),
      );
    });

    test(
      'automatic CPU selection is silent where llamadart picks CPU',
      () async {
        expect(await autoLoadMessages('guarded platform'), isEmpty);
      },
    );

    test('automatic GPU selection does not warn', () async {
      expect(
        await autoLoadMessages(
          null,
          backendName: 'Metal',
          expected: PreferredBackend.gpu,
        ),
        isEmpty,
      );
    });

    test(
      'CPU request refuses GPU placement and disposes exactly once',
      () async {
        engine.backendName = 'Metal';
        final p = await pass(request: PreferredBackend.cpu);
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        await p.close();
        await p.close();
        expect(engine.disposals, 1);
      },
    );

    test('a non-llama.cpp runtime is refused and disposed once', () async {
      engine.loadedRuntime = llama.LlamaRuntime.liteRtLm;
      final p = await pass();
      await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
      await p.close();
      await p.close();
      expect(engine.disposals, 1);
    });

    for (final invalid in <String, List<double>>{
      'zero': [0, 0],
      'nan': [double.nan, 0],
      'infinity': [double.infinity, 0],
      'non-unit': [0.5, 0],
      'near-unit outside tolerance': [1.01, 0],
      'wrong dimension': [1, 0, 0],
    }.entries) {
      test(
        'runtime ${invalid.key} vector fails once and permits recovery',
        () async {
          final p = await pass();
          await p.load();
          engine.vector = invalid.value;
          await expectLater(
            p.embed(EmbeddingInput.text('bad'), TaskType.none),
            throwsA(
              isA<EmbeddingEngineException>().having(
                (e) => e.cause,
                'no double wrapping',
                isNull,
              ),
            ),
          );
          engine.vector = [1, 0];
          expect(await p.embed(EmbeddingInput.text('good'), TaskType.none), [
            1,
            0,
          ]);
        },
      );
    }

    for (final overflow in [false, true]) {
      test(
        'preserves the SDK ${overflow ? "overflow" : "failure"} stack',
        () async {
          final p = await pass();
          await p.load();
          final originalStack = StackTrace.fromString(
            'embedding-sdk-original-stack',
          );
          final original = overflow
              ? llama.LlamaEmbeddingInputTooLongException(
                  'overflow',
                  maxInputTokens: 1024,
                  actualTokens: 1027,
                )
              : llama.LlamaInferenceException('SDK failure');
          engine.failure = original;
          engine.failureStack = originalStack;
          try {
            await p.embed(EmbeddingInput.text('text'), TaskType.none);
            fail('The SDK failure must be reported');
          } catch (error, stack) {
            if (overflow) {
              expect(error, isA<EmbeddingInputTooLongException>());
            } else {
              expect(
                error,
                isA<EmbeddingEngineException>().having(
                  (e) => e.cause,
                  'original SDK cause',
                  same(original),
                ),
              );
            }
            expect(stack.toString(), originalStack.toString());
          }
        },
      );
    }

    test(
      'invalid runtime vector reports dimension, finiteness and norm',
      () async {
        final p = await pass();
        await p.load();
        engine.vector = [1.01, 0];
        await expectLater(
          p.embed(EmbeddingInput.text('bad'), TaskType.none),
          throwsA(
            isA<EmbeddingEngineException>().having(
              (e) => e.message,
              'vector diagnostics',
              allOf(
                contains('expected dimension: 2'),
                contains('actual dimension: 2'),
                contains('finite: true'),
                contains('squared norm: 1.0201'),
              ),
            ),
          ),
        );
      },
    );

    test('accepts vectors within the tight unit-norm tolerance', () async {
      engine.vector = [1.0004, 0];
      final p = await pass();
      expect((await p.load()).dimension, 2);
      expect(await p.embed(EmbeddingInput.text('valid'), TaskType.none), [
        1.0004,
        0,
      ]);
    });

    test('corrupt model load is not retried as GPU availability', () async {
      var attempts = 0;
      final cause = llama.LlamaModelException('invalid GGUF');
      final candidate = createLlamaEmbeddingBackendForTest(
        loader: (_, _) async {
          attempts++;
          throw cause;
        },
      );
      final p = (await candidate.describe(
        _spec('eg2.gguf'),
        _config(backend: PreferredBackend.gpu),
      )).build();
      await expectLater(
        p.load(),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.cause,
            'cause',
            same(cause),
          ),
        ),
      );
      expect(attempts, 1);
      await p.close();
    });

    test(
      'CPU retry failure preserves both errors, second cause and stack',
      () async {
        var attempts = 0;
        final cause = llama.LlamaBackendInitializationException(
          'CPU unavailable',
        );
        final secondStack = StackTrace.fromString('cpu-retry-original-stack');
        final candidate = createLlamaEmbeddingBackendForTest(
          loader: (_, _) async {
            if (++attempts == 1) {
              throw llama.LlamaUnsupportedException('GPU unavailable');
            }
            Error.throwWithStackTrace(cause, secondStack);
          },
        );
        final p = (await candidate.describe(
          _spec('eg2.gguf'),
          _config(backend: PreferredBackend.gpu),
        )).build();
        await expectLater(
          p.load().catchError((Object error, StackTrace stack) {
            expect(stack.toString(), secondStack.toString());
            expect(
              (error as EmbeddingLoadException).message,
              allOf(contains('GPU unavailable'), contains('CPU unavailable')),
            );
            Error.throwWithStackTrace(error, stack);
          }),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.cause,
              'cause',
              same(cause),
            ),
          ),
        );
        expect(attempts, 2);
        await p.close();
      },
    );

    for (final metadata in [
      (
        key: 'general.architecture',
        value: 'bert',
        detail: 'architecture: bert',
      ),
      (
        key: 'gemma-embedding2.pooling_type',
        value: '3',
        detail: 'pooling type: 3',
      ),
      (
        key: 'gemma-embedding2.embedding_length_out',
        value: '512',
        detail: 'declared embedding_length_out: 512',
      ),
    ]) {
      test('load refusal reports ${metadata.key}', () async {
        engine.metadata[metadata.key] = metadata.value;
        final p = await pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'observed metadata',
              contains(metadata.detail),
            ),
          ),
        );
      });
    }

    for (final scenario in [
      'architecture',
      'pooling',
      'capability',
      'context',
      'dimension',
      'missing output dimension',
      'near-unit outside tolerance',
      'zero',
      'nan',
      'infinity',
      'non-unit',
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
          case 'missing output dimension':
            engine.metadata.remove('gemma-embedding2.embedding_length_out');
          case 'near-unit outside tolerance':
            engine.vector = [1.01, 0];
          case 'zero':
            engine.vector = [0, 0];
          case 'nan':
            engine.vector = [double.nan, 0];
          case 'infinity':
            engine.vector = [double.infinity, 0];
          case 'non-unit':
            engine.vector = [0.5, 0];
        }
        final p = await pass();
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        await p.close();
        expect(engine.disposals, 1);
        expect(loadAttempts, 1);
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
  llama.LlamaRuntime? loadedRuntime = llama.LlamaRuntime.llamaCpp;
  bool supported = true;
  int context = 1024;
  int disposals = 0;
  Object? failure;
  StackTrace? failureStack;
  List<double> vector = [1, 0];
  final inputs = <String>[];
  @override
  llama.LlamaRuntime? get runtime => loadedRuntime;
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
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
    }
    return vector;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

// This is an overlapping generic fallback, not a fake LiteRT implementation.
// Real LiteRT does not claim self-contained GGUF; this deliberately overlaps
// so the actual registry's priority ordering is exercised in both orders.
final class _GenericFallbackBackend extends EmbeddingBackendProvider {
  const _GenericFallbackBackend();

  @override
  String get name => 'generic test fallback';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async => throw UnsupportedError('routing-only test provider');
}
