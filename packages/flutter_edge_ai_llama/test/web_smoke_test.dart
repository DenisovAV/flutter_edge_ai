@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

// Core storage fixtures avoid downloads while exercising the real Web facade.
// ignore: implementation_imports — seeds core storage for the real Web facade without downloads.
import 'package:flutter_edge_ai/src/di/service_registry.dart';
// ignore: implementation_imports — registers a deterministic URL in the Web facade fixture.
import 'package:flutter_edge_ai/src/infrastructure/web_file_system_service.dart';
// ignore: implementation_imports — activates and clears the Web facade storage fixture.
import 'package:flutter_edge_ai/src/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — constructs installed metadata for the Web facade fixture.
import 'package:flutter_edge_ai/src/services/model_repository.dart'
    as repository;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
// ignore: implementation_imports — registers the real Web platform shell for browser tests.
import 'package:flutter_edge_ai/src/web/flutter_edge_ai_web.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

const _modelUrl = String.fromEnvironment('GGUF_WEB_MODEL_URL');
const _storageHelperUrl = String.fromEnvironment('GGUF_WEB_STORAGE_HELPER_URL');
const _bridgeRoot = String.fromEnvironment(
  'GGUF_WEB_BRIDGE_ROOT',
  defaultValue: '/webgpu_bridge/',
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Web provider selects the supplied real spec and rejects other formats',
    () async {
      final sentinel = llama.LlamaStateException('Loader reached');
      final provider = LlamaEngineProvider(
        loader: (location, params) async {
          expect(location, 'https://example.test/model.gguf');
          throw sentinel;
        },
      );
      for (final filename in ['model.gguf', 'other.bin', 'other.task']) {
        final spec = edge.InferenceModelSpec(
          name: filename,
          modelSource: edge.NetworkSource('https://example.test/$filename'),
          modelType: edge.ModelType.general,
          fileType: edge.ModelFileType.binary,
        );
        expect(provider.canHandle(spec), filename.endsWith('.gguf'));
        await expectLater(
          provider.createModel(
            spec,
            RuntimeConfig(
              modelPath: 'https://example.test/$filename',
              maxTokens: 512,
            ),
          ),
          filename.endsWith('.gguf')
              ? throwsA(same(sentinel))
              : throwsA(isA<llama.LlamaUnsupportedException>()),
        );
      }
    },
  );

  test(
    'Web facade reuses a model and waits for app-initiated close before reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      edge.FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
      final engines = <_WebEngine>[];
      final gate = Completer<void>();
      final provider = LlamaEngineProvider(
        loader: (location, params) async {
          expect(location, 'https://example.test/model.gguf');
          final engine = _WebEngine();
          if (engines.isEmpty) engine.disposeGate = gate;
          engines.add(engine);
          return engine;
        },
      );
      await edge.FlutterEdgeAi.initialize(
        inferenceEngines: [provider],
        webStorageMode: edge.WebStorageMode.none,
      );
      final manager =
          edge.FlutterEdgeAiPlugin.instance.modelManager as WebModelManager;
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await edge.FlutterEdgeAiPlugin.instance.initializedModel?.close();
        await manager.clearActiveInferenceIdentity();
        await edge.FlutterEdgeAi.dispose();
      });
      final spec = edge.InferenceModelSpec(
        name: 'model.gguf',
        modelSource: edge.NetworkSource('https://example.test/model.gguf'),
        modelType: edge.ModelType.general,
        fileType: edge.ModelFileType.binary,
      );
      final services = ServiceRegistry.instance;
      await services.modelRepository.saveModel(
        repository.ModelInfo(
          id: spec.files.first.filename,
          source: spec.modelSource,
          installedAt: DateTime.now(),
          sizeBytes: 1,
          type: repository.ModelType.inference,
          hasLoraWeights: false,
        ),
      );
      (services.fileSystemService as WebFileSystemService).registerUrl(
        spec.files.first.filename,
        'https://example.test/model.gguf',
      );
      await manager.activateInstalledModel(spec);
      final first = await edge.FlutterEdgeAi.getActiveModel(maxTokens: 512);
      expect(
        await edge.FlutterEdgeAi.getActiveModel(maxTokens: 512),
        same(first),
      );
      expect(engines, hasLength(1));
      final closing = first.close();
      expect(first.isClosed, isTrue);
      await engines.first.disposeStarted.future.timeout(
        const Duration(seconds: 2),
      );
      var replaced = false;
      final pending = edge.FlutterEdgeAi.getActiveModel(maxTokens: 512)
          .then((model) {
            replaced = true;
            return model;
          });
      await Future<void>.delayed(Duration.zero);
      expect(replaced, isFalse);
      expect(engines, hasLength(1));
      gate.complete();
      await closing;
      final replacement = await pending.timeout(const Duration(seconds: 2));
      expect(replacement, isNot(same(first)));
      expect(replacement.isClosed, isFalse);
      expect(engines, hasLength(2));
      expect(engines.first.disposals, 1);
    },
  );
  test(
    'real browser facade installs a URL and runs GGUF generation',
    () async {
      Object? failure;
      final completed = await binding.runAsync<bool>(() async {
        try {
          // ignore: avoid_print
          print('WEB_SMOKE: initializing bridge');
          if (!web.window.crossOriginIsolated) {
            throw StateError('Run this smoke with --cross-origin-isolation.');
          }
          final storageReady = Completer<void>();
          final storageHelper = web.HTMLScriptElement()
            ..src = _storageHelperUrl.isEmpty
                ? Uri.parse(_modelUrl).resolve('cache_api.js').toString()
                : _storageHelperUrl;
          storageHelper.onload = ((web.Event _) {
            storageReady.complete();
          }).toJS;
          storageHelper.onerror = ((web.Event _) {
            storageReady.completeError(
              StateError('Core storage helper failed to load.'),
            );
          }).toJS;
          web.document.head!.appendChild(storageHelper);
          await storageReady.future.timeout(const Duration(seconds: 20));
          final ready = Completer<void>();
          final listener = ((web.Event _) {
            if (!ready.isCompleted) ready.complete();
          }).toJS;
          web.window.addEventListener('llama-test-ready', listener);
          addTearDown(
            () => web.window.removeEventListener('llama-test-ready', listener),
          );
          final script = web.HTMLScriptElement()..type = 'module';
          script.textContent =
              '''
      const root = new URL('$_bridgeRoot', document.baseURI).href;
      const module = await import(root + 'llama_webgpu_bridge.js');
      window.LlamaWebGpuBridge = module.LlamaWebGpuBridge;
      window.__llamadartBridgeCoreModuleUrl = root + 'llama_webgpu_core.js';
      window.__llamadartBridgeWasmUrl = root + 'llama_webgpu_core.wasm';
      window.__llamadartBridgeWorkerUrl = root + 'llama_webgpu_bridge_worker.js';
      window.__llamadartBridgeThreadPoolSize = 1;
      window.dispatchEvent(new Event('llama-test-ready'));
    ''';
          web.document.head!.appendChild(script);
          await ready.future.timeout(const Duration(seconds: 45));
          // ignore: avoid_print
          print('WEB_SMOKE: bridge loaded');
          SharedPreferences.setMockInitialValues({});
          edge.FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
          edge.FlutterEdgeAi.logLevel = edge.EdgeAiLogLevel.none;
          await edge.FlutterEdgeAi.initialize(
            inferenceEngines: [
              LlamaEngineProvider(
                loader: (location, params) async {
                  // ignore: avoid_print
                  print('WEB_SMOKE: loading engine');
                  final engine = await loadGgufEngine(location, params);
                  // ignore: avoid_print
                  print('WEB_SMOKE: engine loaded');
                  return engine;
                },
              ),
            ],
            webStorageMode: edge.WebStorageMode.none,
          );
          await edge.FlutterEdgeAi.installModel(
            modelType: edge.ModelType.general,
            fileType: edge.ModelFileType.binary,
          ).fromNetwork(_modelUrl).install();
          // ignore: avoid_print
          print('WEB_SMOKE: installed model URL');
          llama.LlamaLogging.configure(level: llama.LlamaLogLevel.error);
          final model = await edge.FlutterEdgeAi.getActiveModel(
            maxTokens: 2048,
          );
          // ignore: avoid_print
          print('WEB_SMOKE: model loaded on ${model.activeBackend}');
          addTearDown(model.close);
          final chat = await model.openChat(
            temperature: 0,
            maxOutputTokens: 16,
          );
          await chat.addQuery(
            edge.Message.text(text: 'Say hello.', isUser: true),
          );
          final response =
              await chat.generateChatResponse() as edge.TextResponse;
          expect(response.token.trim(), isNotEmpty);
          // ignore: avoid_print
          print(
            'WEB_SMOKE: generated a nonempty reply (${response.token.length} characters)',
          );
          return true;
        } catch (error, stack) {
          failure = "$error\n$stack";
          return false;
        }
      });
      expect(
        completed,
        isTrue,
        reason: 'Model loading and generation must finish. $failure',
      );
    },
    skip: _modelUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _WebBackend implements llama.LlamaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WebEngine extends llama.LlamaEngine {
  _WebEngine() : super(_WebBackend());

  Completer<void>? disposeGate;
  final Completer<void> disposeStarted = Completer<void>();
  int disposals = 0;

  @override
  llama.LlamaRuntime get runtime => llama.LlamaRuntime.llamaCpp;

  @override
  Future<int> getContextSize() async => 512;

  @override
  Future<int?> getResolvedGpuLayers() async => 0;

  @override
  Future<void> dispose() async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await disposeGate?.future;
    disposals++;
  }
}
