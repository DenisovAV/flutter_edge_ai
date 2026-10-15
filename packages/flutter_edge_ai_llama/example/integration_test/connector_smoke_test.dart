import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
// ignore: implementation_imports — test-only factory for the explicit CPU smoke profile.
import 'package:flutter_edge_ai_llama/src/llama_engine_provider.dart'
    show createLlamaProviderForTest;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai_llama_demo/model_import_native.dart';
import 'package:llamadart/llamadart.dart' as llama;

const _modelPath = String.fromEnvironment('GGUF_MODEL_PATH');
const _modelUrl = String.fromEnvironment('GGUF_MODEL_URL');
const _cpuThreads = int.fromEnvironment('GGUF_CPU_THREADS');

Future<llama.LlamaEngine> _loadWithThreadBudget(
  String path,
  llama.ModelParams params,
) => llama.LlamaEngine.load(
  llama.LlamaModel(
    llama.ModelSource.path(path, format: llama.ModelFormat.gguf),
  ),
  params: params.copyWith(
    numberOfThreads: _cpuThreads,
    numberOfThreadsBatch: _cpuThreads,
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (defaultTargetPlatform == TargetPlatform.iOS) {
    testWidgets(
      'iOS picker import moves the owned tmp copy into durable storage',
      (tester) async {
        final temporary = Directory.systemTemp;
        final inbox = Directory('${temporary.path}/dev.llamadart-Inbox');
        await inbox.create(recursive: true);
        final source = File(
          '${inbox.path}/qa_${DateTime.now().microsecondsSinceEpoch}.gguf',
        );
        await source.writeAsBytes([71, 71, 85, 70]);
        File? imported;
        try {
          imported = File(
            await importModel(source.path, cleanupPickerInbox: true),
          );
          expect(await imported.readAsBytes(), [71, 71, 85, 70]);
          expect(await source.exists(), isFalse);
          expect(imported.path, contains('/gguf_lab/'));
        } finally {
          if (await source.exists()) await source.delete();
          if (imported != null && await imported.exists()) {
            await imported.delete();
          }
          if (await inbox.list().isEmpty) await inbox.delete();
        }
      },
    );
  }

  testWidgets('packaged native runtime installs, generates, cancels and reloads', (
    tester,
  ) async {
    expect(
      _modelPath.isNotEmpty || _modelUrl.isNotEmpty,
      isTrue,
      reason:
          'Supply GGUF_MODEL_PATH on the target device or GGUF_MODEL_URL. This required smoke never skips.',
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('GGUF qualification'))),
    );
    await tester.runAsync(() async {
      final elapsed = Stopwatch()..start();
      void logStage(String stage) => debugPrint(
        'DEVICE_SMOKE: elapsedMs=${elapsed.elapsedMilliseconds} $stage',
      );
      llama.LlamaLogging.configure(level: llama.LlamaLogLevel.error);
      edge.FlutterEdgeAi.logLevel = edge.EdgeAiLogLevel.none;
      expect(_cpuThreads, greaterThanOrEqualTo(0));
      logStage('stage=initialize cpuThreads=$_cpuThreads');
      await edge.FlutterEdgeAi.initialize(
        inferenceEngines: [
          if (_cpuThreads > 0)
            createLlamaProviderForTest(loader: _loadWithThreadBudget)
          else
            const LlamaEngineProvider(),
        ],
      );
      final installation = edge.FlutterEdgeAi.installModel(
        modelType: edge.ModelType.general,
        fileType: edge.ModelFileType.gguf,
      );
      logStage('stage=install');
      if (_modelPath.isNotEmpty) {
        await installation.fromFile(_modelPath).install();
      } else {
        await installation.fromNetwork(_modelUrl).install();
      }
      for (var cycle = 0; cycle < 3; cycle++) {
        logStage('cycle=$cycle stage=load');
        final model = await edge.FlutterEdgeAi.getActiveModel(
          maxTokens: 2048,
          preferredBackend: edge.PreferredBackend.cpu,
        );
        try {
          expect(model, isA<edge.InferenceModel>());
          expect(model.activeBackend, edge.PreferredBackend.cpu);
          logStage('cycle=$cycle stage=chat');
          final chat = await model.openChat(
            systemInstruction: 'Follow instructions. Keep your answers short.',
            temperature: 0,
            maxOutputTokens: 64,
          );
          logStage('cycle=$cycle stage=first-response');
          await chat.addQuery(
            edge.Message.text(
              text: 'Remember this secret word: orchid. Reply with OK.',
              isUser: true,
            ),
          );
          expect(
            (await chat.generateChatResponse() as edge.TextResponse).token
                .trim(),
            isNotEmpty,
          );
          logStage('cycle=$cycle stage=recall');
          await chat.addQuery(
            edge.Message.text(
              text: 'What is the secret word? Answer with only that word.',
              isUser: true,
            ),
          );
          expect(
            (await chat.generateChatResponse() as edge.TextResponse).token
                .toLowerCase(),
            contains('orchid'),
          );
          await chat.close();

          if (cycle == 0) {
            logStage('cycle=$cycle stage=context-trimming');
            final bounded = await model.openChat(
              temperature: 0,
              maxOutputTokens: 16,
              tokenBuffer: 256,
            );
            try {
              for (var turn = 0; turn < 3; turn++) {
                await bounded.addQuery(
                  edge.Message.text(
                    text:
                        'Reply OK. Background: ${List.filled(600, 'context').join(' ')}. Turn $turn.',
                    isUser: true,
                  ),
                );
                expect(
                  (await bounded.generateChatResponse() as edge.TextResponse)
                      .token
                      .trim(),
                  isNotEmpty,
                );
              }
              final retained = bounded.fullHistory.where(
                (m) => m.isUser && m.type == edge.MessageType.text,
              );
              expect(
                retained.length,
                3,
                reason:
                    'Runtime trimming must preserve the full visible transcript.',
              );
              expect(retained.last.text, endsWith('Turn 2.'));
            } finally {
              await bounded.close();
            }
          }

          final session = await model.openSession(
            temperature: 0,
            maxOutputTokens: 256,
          );
          await session.addQueryChunk(
            edge.Message.text(
              text: 'Write a long story about an ocean voyage.',
              isUser: true,
            ),
          );
          final first = Completer<void>();
          final complete = Completer<void>();
          final stream = session.getResponseAsync().listen(
            (_) {
              if (!first.isCompleted) first.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (!first.isCompleted) first.completeError(error, stack);
              if (!complete.isCompleted) complete.completeError(error, stack);
            },
            onDone: () {
              if (!complete.isCompleted) complete.complete();
            },
          );
          try {
            logStage('cycle=$cycle stage=cancel');
            await first.future.timeout(const Duration(seconds: 60));
            await session.stopGeneration().timeout(const Duration(seconds: 15));
            await complete.future.timeout(const Duration(seconds: 15));
          } finally {
            await stream.cancel();
          }
          await session.addQueryChunk(
            edge.Message.text(text: 'Say hello.', isUser: true),
          );
          logStage('cycle=$cycle stage=retry');
          expect((await session.getResponse()).trim(), isNotEmpty);
        } finally {
          logStage('cycle=$cycle stage=close');
          await model.close();
        }
      }
      logStage('completed=3');
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
