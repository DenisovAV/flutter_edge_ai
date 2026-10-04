import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import 'chat_page.dart';
import 'download_page.dart';
import 'model.dart';

/// Change this one line to run the whole app on a different model. On web
/// it stays `Models.gemma4Web` — the browser engine only runs `.litertlm`
/// files exported for it, and that is the only one published.
const _model = kIsWeb ? Models.gemma4Web : Models.gemma3;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Engines are fully opt-in: the core package registers none by itself.
  // Without LiteRtLmEngine here, the first model call throws a StateError
  // that tells you to add an engine package.
  await FlutterEdgeAi.initialize(
    inferenceEngines: [LiteRtLmEngine()],
    // The embedding backend runs the forward pass. It comes from the same
    // engine package as the LLM engine above — one native runtime serves both.
    embeddingBackends: [LiteRtEmbeddingBackend()],
    // ...and the tokenizer comes from somewhere else on purpose. Which
    // tokenizer a model needs is a property of the MODEL, not of the engine:
    // EmbeddingGemma wants SentencePiece whether LiteRT or ONNX Runtime runs
    // it. Leave this out and the first embedding throws a StateError naming
    // the package to add — it will never quietly tokenize with the wrong
    // convention and hand you vectors from the wrong point in the space.
    embeddingTokenizers: [GemmaEmbeddingTokenizers()],
    // The store the vectors go into. Two classes, one per platform arm: the
    // native one is sqlite3 over dart:ffi with the `vec0` extension loaded,
    // the web one is the same SQLite compiled to WASM with `vec0` linked in
    // and its pages kept in IndexedDB. Both implement the same
    // `VectorStoreRepository`, which is what makes everything after this line
    // platform-independent — and what makes the swap in Step 3 one line.
    vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
    huggingFaceToken: hfToken.isEmpty ? null : hfToken,
    // OPFS streaming. On web the model is 2.0 GB, right on the ~2 GB blob
    // ceiling the default `cacheApi` mode would have to buffer it into.
    // The other platforms ignore this option.
    webStorageMode: WebStorageMode.streaming,
  );

  runApp(const QuickstartApp());
}

class QuickstartApp extends StatelessWidget {
  const QuickstartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge AI Quickstart',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const ModelGate(model: _model),
    );
  }
}

/// Asks, on every cold start, whether the model is already installed.
///
/// `install()` is idempotent, so the bytes are only ever fetched once. What a
/// drifted id costs you is this gate: it answers "no" forever, so the app
/// shows the download screen on every launch, the "download" there finishes
/// instantly, and you land straight back here. Delete the model with the chat's
/// delete button and relaunch to watch this branch flip back.
class ModelGate extends StatefulWidget {
  const ModelGate({super.key, required this.model});

  final ModelChoice model;

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
          // A FutureBuilder that ignores `hasError` renders the download
          // screen as if nothing had gone wrong. Say what failed instead.
          return _GateError(
            error: snapshot.error!,
            onRetry: () => setState(() => _installed = _check()),
          );
        }
        if (snapshot.data ?? false) {
          return ChatPage(
            model: widget.model,
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

/// Shown when the gate's own check fails, rather than falling through to the
/// download screen as if the answer had been "no".
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
