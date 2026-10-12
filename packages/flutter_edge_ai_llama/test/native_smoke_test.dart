import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _modelPath = String.fromEnvironment('GGUF_MODEL_PATH');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'published facade installs GGUF, chats, cancels and reloads',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'edge-llama-smoke-',
      );
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(scratch.path);
      SharedPreferences.setMockInitialValues({});
      llama.LlamaLogging.configure(level: llama.LlamaLogLevel.error);
      edge.FlutterEdgeAi.logLevel = edge.EdgeAiLogLevel.none;
      edge.InferenceModel? loaded;
      addTearDown(() async {
        await loaded?.close();
        PathProviderPlatform.instance = originalPaths;
        await scratch.delete(recursive: true);
      });

      expect(
        await File(_modelPath).exists(),
        isTrue,
        reason: 'Supply an existing GGUF file.',
      );
      await edge.FlutterEdgeAi.initialize(
        inferenceEngines: const [LlamaEngineProvider()],
      );
      await edge.FlutterEdgeAi.installModel(
        modelType: edge.ModelType.general,
        fileType: edge.ModelFileType.binary,
      ).fromFile(_modelPath).install();
      loaded = await edge.FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.cpu,
      );
      expect(loaded, isA<LlamaInferenceModel>());
      expect(loaded.activeBackend, edge.PreferredBackend.cpu);
      final chat = await loaded.createChat(
        systemInstruction: 'Follow instructions. Keep your answers short.',
        temperature: 0,
        maxOutputTokens: 64,
        modelType: edge.ModelType.general,
      );
      await chat.addQueryChunk(
        edge.Message.text(
          text: 'Remember this secret word: orchid. Reply with OK.',
          isUser: true,
        ),
      );
      final first = await _reply(chat);
      expect(first.trim(), isNotEmpty);
      await chat.addQueryChunk(
        edge.Message.text(
          text: 'What is the secret word? Answer with only that word.',
          isUser: true,
        ),
      );
      final recalled = await _reply(chat);
      expect(recalled.toLowerCase(), contains('orchid'));
      final metrics = chat.session.getSessionMetrics();
      expect(metrics.inputTokens, greaterThan(0));
      expect(metrics.outputTokens, greaterThan(0));
      expect(metrics.totalTokens, metrics.inputTokens + metrics.outputTokens);

      final cancellable = await loaded.createSession(
        temperature: 0,
        maxOutputTokens: 256,
      );
      await cancellable.addQueryChunk(
        edge.Message.text(
          text: 'Write a long detailed story about a voyage across the ocean.',
          isUser: true,
        ),
      );
      final firstToken = Completer<void>();
      final streamDone = Completer<void>();
      final subscription = cancellable.getResponseAsync().listen(
        (_) {
          if (!firstToken.isCompleted) firstToken.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!firstToken.isCompleted) firstToken.completeError(error, stack);
          if (!streamDone.isCompleted) streamDone.completeError(error, stack);
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
      );
      await firstToken.future.timeout(const Duration(seconds: 30));
      await cancellable.stopGeneration().timeout(const Duration(seconds: 10));
      await streamDone.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      await cancellable.addQueryChunk(
        edge.Message.text(text: 'Say hello in one sentence.', isUser: true),
      );
      final afterStop = await cancellable.getResponse();
      expect(afterStop.trim(), isNotEmpty);

      await loaded.close();
      // Fresh plugin/manager rehydrates the active identity from persisted prefs.
      FlutterEdgeAiDesktop.registerWith();
      await edge.FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
      expect(
        (edge.FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel
                as edge.InferenceModelSpec)
            .fileType,
        edge.ModelFileType.binary,
      );
      expect(
        edge
            .FlutterEdgeAiPlugin
            .instance
            .modelManager
            .activeInferenceModel
            ?.files
            .first
            .filename,
        endsWith('.gguf'),
      );
      final reloaded = await edge.FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.cpu,
      );
      expect(reloaded, isNot(same(loaded)));
      loaded = reloaded;
      final fresh = await reloaded.createSession(
        temperature: 0,
        maxOutputTokens: 32,
      );
      await fresh.addQueryChunk(
        edge.Message.text(text: 'Say hello.', isUser: true),
      );
      expect((await fresh.getResponse()).trim(), isNotEmpty);
      // ignore: avoid_print
      print(
        'NATIVE_SMOKE: backend=${reloaded.activeBackend?.name} '
        'first=${first.trim()} recall=${recalled.trim()} '
        'tokens=${metrics.inputTokens}/${metrics.outputTokens} '
        'afterStop=${afterStop.trim()}',
      );
    },
    skip: _modelPath.isEmpty
        ? 'Set --dart-define=GGUF_MODEL_PATH=/absolute/model.gguf'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<String> _reply(edge.InferenceChat chat) async =>
    (await chat
            .generateChatResponseAsync()
            .where((r) => r is edge.TextResponse)
            .cast<edge.TextResponse>()
            .map((r) => r.token)
            .toList())
        .join();

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
