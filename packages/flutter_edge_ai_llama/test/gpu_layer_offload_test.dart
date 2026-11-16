@TestOn('vm')
library;

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/src/llama_engine_provider.dart'
    show LlamaEngineProvider, createLlamaProviderForTest;
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

void main() {
  late llama.ModelParams? loaded;
  late int loaderCalls;

  setUp(() {
    loaded = null;
    loaderCalls = 0;
  });

  // The loader records the params and stops the load before any engine exists.
  Future<llama.LlamaEngine> recordParams(
    String path,
    llama.ModelParams params,
  ) async {
    loaderCalls++;
    loaded = params;
    throw StateError('stop after recording params');
  }

  test('offloads the layers the planner sizes for the context', () async {
    final planned = <Object>[];
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayerPlanner: (location, contextTokens) async {
        planned.addAll([location, contextTokens]);
        return 12;
      },
    );

    await _expectLoadStops(
      provider,
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 32768,
        preferredBackend: edge.PreferredBackend.gpu,
      ),
    );

    expect(planned, ['/models/model.gguf', 32768]);
    expect(loaded!.device, llama.ComputeDevice.gpu);
    expect(loaded!.gpuLayers, 12);
  });

  test('keeps every layer when the planner says all of them fit', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayerPlanner: (location, contextTokens) async =>
          llama.ModelParams.maxGpuLayers,
    );

    await _expectLoadStops(
      provider,
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.gpu,
      ),
    );

    expect(loaded!.gpuLayers, llama.ModelParams.maxGpuLayers);
  });

  test('auto backend loads on CPU when no layer fits', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayerPlanner: (location, contextTokens) async => 0,
    );

    await _expectLoadStops(
      provider,
      const RuntimeConfig(modelPath: '/models/model.gguf', maxTokens: 2048),
    );

    expect(loaded!.device, llama.ComputeDevice.cpu);
    expect(loaded!.gpuLayers, 0);
  });

  test('explicit GPU fails before loading when no layer fits', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayerPlanner: (location, contextTokens) async => 0,
    );

    await expectLater(
      provider.createModel(
        _spec(),
        const RuntimeConfig(
          modelPath: '/models/model.gguf',
          maxTokens: 32768,
          preferredBackend: edge.PreferredBackend.gpu,
        ),
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(loaderCalls, 0);
  });

  test('CPU backend never asks the planner', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayerPlanner: (location, contextTokens) async =>
          fail('The CPU backend must not size GPU layers.'),
    );

    await _expectLoadStops(
      provider,
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.cpu,
      ),
    );

    expect(loaded!.device, llama.ComputeDevice.cpu);
    expect(loaded!.gpuLayers, 0);
  });
}

Future<void> _expectLoadStops(
  LlamaEngineProvider provider,
  RuntimeConfig config,
) async {
  await expectLater(provider.createModel(_spec(), config), throwsA(anything));
}

edge.InferenceModelSpec _spec() => edge.InferenceModelSpec(
  name: 'model.gguf',
  modelSource: edge.ModelSource.file('/models/model.gguf'),
  modelType: edge.ModelType.general,
  fileType: edge.ModelFileType.gguf,
);
