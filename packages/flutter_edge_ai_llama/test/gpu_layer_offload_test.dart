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

  test('offloads the layers the resolver returns', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async => 12,
    );

    await _expectLoadStops(
      provider,
      _spec(),
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 32768,
        preferredBackend: edge.PreferredBackend.gpu,
      ),
    );

    expect(loaded!.device, llama.ComputeDevice.gpu);
    expect(loaded!.gpuLayers, 12);
  });

  test('passes the selected spec and config to the resolver', () async {
    final spec = _spec();
    const config = RuntimeConfig(
      modelPath: '/models/model.gguf',
      maxTokens: 2048,
      preferredBackend: edge.PreferredBackend.gpu,
    );
    edge.InferenceModelSpec? receivedSpec;
    RuntimeConfig? receivedConfig;
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async {
        receivedSpec = spec;
        receivedConfig = config;
        return 20;
      },
    );

    await _expectLoadStops(provider, spec, config);

    expect(identical(receivedSpec, spec), isTrue);
    expect(identical(receivedConfig, config), isTrue);
  });

  test('null from the resolver offloads every layer', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async => null,
    );

    await _expectLoadStops(
      provider,
      _spec(),
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.gpu,
      ),
    );

    expect(loaded!.device, llama.ComputeDevice.gpu);
    expect(loaded!.gpuLayers, llama.ModelParams.maxGpuLayers);
  });

  test('without a resolver every layer is offloaded', () async {
    final provider = createLlamaProviderForTest(loader: recordParams);

    await _expectLoadStops(
      provider,
      _spec(),
      const RuntimeConfig(
        modelPath: '/models/model.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.gpu,
      ),
    );

    expect(loaded!.device, llama.ComputeDevice.gpu);
    expect(loaded!.gpuLayers, llama.ModelParams.maxGpuLayers);
  });

  test('zero layers on the auto backend keeps the device auto', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async => 0,
    );

    await _expectLoadStops(
      provider,
      _spec(),
      const RuntimeConfig(modelPath: '/models/model.gguf', maxTokens: 2048),
    );

    expect(loaded!.device, llama.ComputeDevice.auto);
    expect(loaded!.gpuLayers, 0);
  });

  test('a negative layer count fails before loading', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async => -1,
    );

    await expectLater(
      provider.createModel(
        _spec(),
        const RuntimeConfig(
          modelPath: '/models/model.gguf',
          maxTokens: 2048,
          preferredBackend: edge.PreferredBackend.gpu,
        ),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('returned -1'),
        ),
      ),
    );
    expect(loaderCalls, 0);
  });

  test('a resolver error propagates unchanged before loading', () async {
    final failure = StateError('resolver failed');
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async => throw failure,
    );

    await expectLater(
      provider.createModel(
        _spec(),
        const RuntimeConfig(
          modelPath: '/models/model.gguf',
          maxTokens: 2048,
          preferredBackend: edge.PreferredBackend.gpu,
        ),
      ),
      throwsA(same(failure)),
    );
    expect(loaderCalls, 0);
  });

  test('CPU backend never calls the resolver', () async {
    final provider = createLlamaProviderForTest(
      loader: recordParams,
      gpuLayersResolver: (spec, config) async =>
          fail('The CPU backend must not size GPU layers.'),
    );

    await _expectLoadStops(
      provider,
      _spec(),
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
  edge.InferenceModelSpec spec,
  RuntimeConfig config,
) async {
  await expectLater(provider.createModel(spec, config), throwsA(anything));
}

edge.InferenceModelSpec _spec() => edge.InferenceModelSpec(
  name: 'model.gguf',
  modelSource: edge.ModelSource.file('/models/model.gguf'),
  modelType: edge.ModelType.general,
  fileType: edge.ModelFileType.gguf,
);
