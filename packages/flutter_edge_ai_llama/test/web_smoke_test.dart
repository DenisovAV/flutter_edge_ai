@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai/web/flutter_edge_ai_web.dart';
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
    'Web synthetic probe uses the active identity and rejects other formats',
    () async {
      SharedPreferences.setMockInitialValues({});
      edge.FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
      final manager =
          edge.FlutterEdgeAiPlugin.instance.modelManager as WebModelManager;
      final probe = edge.InferenceModelSpec(
        name: 'web-active',
        modelSource: edge.AssetSource('models/active.bin'),
        modelType: edge.ModelType.general,
        fileType: edge.ModelFileType.binary,
      );
      final sentinel = llama.LlamaStateException('Loader reached');
      final provider = LlamaEngineProvider(
        loader: (location, params) async {
          expect(location, 'https://example.test/model.gguf');
          throw sentinel;
        },
      );
      expect(provider.canHandle(probe), isFalse);
      for (final filename in ['model.gguf', 'other.bin', 'other.task']) {
        await manager.activateInstalledModel(
          edge.InferenceModelSpec(
            name: filename,
            modelSource: edge.NetworkSource('https://example.test/$filename'),
            modelType: edge.ModelType.general,
            fileType: edge.ModelFileType.binary,
          ),
        );
        expect(provider.canHandle(probe), filename.endsWith('.gguf'));
        if (filename.endsWith('.gguf')) {
          await expectLater(
            provider.createModel(
              probe,
              const RuntimeConfig(
                modelPath: 'https://example.test/model.gguf',
                maxTokens: 512,
              ),
            ),
            throwsA(same(sentinel)),
          );
        } else {
          await expectLater(
            provider.createModel(
              probe,
              const RuntimeConfig(
                modelPath: 'https://example.test/other.bin',
                maxTokens: 512,
              ),
            ),
            throwsA(isA<llama.LlamaUnsupportedException>()),
          );
        }
      }
      await edge.FlutterEdgeAi.initialize(
        webStorageMode: edge.WebStorageMode.none,
      );
      await manager.clearActiveInferenceIdentity();
      expect(provider.canHandle(probe), isFalse);
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
