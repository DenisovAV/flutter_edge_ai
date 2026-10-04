import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'chat_page.dart';
import 'download_page.dart';
import 'model.dart';
import 'rag_store.dart';

const _model = kIsWeb ? Models.gemma4Web : Models.gemma3;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: [LiteRtLmEngine()],
    embeddingBackends: [LiteRtEmbeddingBackend()],
    embeddingTokenizers: [GemmaEmbeddingTokenizers()],
    huggingFaceToken: hfToken.isEmpty ? null : hfToken,
    webStorageMode: WebStorageMode.streaming,
  );

  // The path versions both the embedding profile and the physical filter
  // schema. Do not reuse the old recipes.db: its vectors have no attestable
  // profile, and sqlite-vec cannot ALTER an existing vec0 filter schema.
  final ragStore = RagStore(
    databaseName: 'recipes-embeddinggemma-29888fcee321-filters-v1.db',
    filterSchema: FilterSchema(
      fields: [
        FilterField(name: 'cuisine', type: FilterFieldType.string),
        FilterField(name: 'minutes', type: FilterFieldType.number),
        FilterField(name: 'vegetarian', type: FilterFieldType.bool),
      ],
    ),
  );

  runApp(QuickstartApp(ragStore: ragStore));
}

class QuickstartApp extends StatefulWidget {
  const QuickstartApp({super.key, required this.ragStore});

  final RagStore ragStore;

  @override
  State<QuickstartApp> createState() => _QuickstartAppState();
}

class _QuickstartAppState extends State<QuickstartApp> {
  late final AppLifecycleListener _lifecycle;
  Future<void>? _shutdown;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onDetach: () => unawaited(_disposeOwnedResources()),
    );
  }

  Future<void> _disposeOwnedResources() => _shutdown ??= () async {
    // The RagIndex borrows core's active embedder, so ordering is load-bearing.
    await widget.ragStore.dispose();
    await FlutterEdgeAi.dispose();
  }();

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_disposeOwnedResources());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge AI Quickstart',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: ModelGate(model: _model, ragStore: widget.ragStore),
    );
  }
}

class ModelGate extends StatefulWidget {
  const ModelGate({super.key, required this.model, required this.ragStore});

  final ModelChoice model;
  final RagStore ragStore;

  @override
  State<ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends State<ModelGate> {
  late Future<bool> _installed = _check();

  Future<bool> _check() =>
      FlutterEdgeAi.isModelInstalled(widget.model.fileName);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _installed,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return _GateError(
            error: snapshot.error!,
            onRetry: () => setState(() => _installed = _check()),
          );
        }
        if (snapshot.data ?? false) {
          return ChatPage(
            model: widget.model,
            ragStore: widget.ragStore,
            onModelRemoved: () => setState(() => _installed = _check()),
          );
        }
        return DownloadPage(
          model: widget.model,
          onInstalled: () => setState(() => _installed = _check()),
        );
      },
    );
  }
}

class _GateError extends StatelessWidget {
  const _GateError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
