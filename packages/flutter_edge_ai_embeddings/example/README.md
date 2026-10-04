# flutter_edge_ai_embeddings example

`flutter_edge_ai_embeddings` supplies the embedding **tokenizers** for
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai) — Gemma
SentencePiece and BERT-family WordPiece. Since 2.2.0 that is all it is: the
forward-pass seam, the background-isolate worker and the pooling live in
`flutter_edge_ai` itself, and the backend comes from an engine package, e.g.
[`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm)'s
`LiteRtEmbeddingBackend` (Gecko / EmbeddingGemma `.tflite` via the LiteRT C
API — dart:ffi on the 5 native platforms, LiteRT.js on web). Register both once
at startup, then embed text and feed the vectors into a RAG index.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The backend comes from an engine package; the tokenizers from this one.
  await FlutterEdgeAi.initialize(
    embeddingBackends: [LiteRtEmbeddingBackend()],   // flutter_edge_ai_litertlm
    embeddingTokenizers: [GemmaEmbeddingTokenizers()],
  );

  // Install an embedding model (downloads + sets it active). The model and its
  // tokenizer are separate downloads.
  await FlutterEdgeAi.installEmbedder()
      .modelFromNetwork('https://example.com/embeddinggemma.tflite', token: 'hf_...')
      .tokenizerFromNetwork('https://example.com/sentencepiece.model', token: 'hf_...')
      .install();

  // Create the embedding model and embed text.
  final embedder = await FlutterEdgeAi.getActiveEmbedder();
  final vector = await embedder.generateEmbedding('Gemma runs on-device.');
  print('embedding dim: ${vector.length}');

  await embedder.close();
}
```

For on-device retrieval, use
[`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag) with a
storage provider: `flutter_edge_ai_sqlite` (all six platforms, Web included) or
`flutter_edge_ai_qdrant` (native only). A full runnable
app lives in the
[`flutter_edge_ai` example](https://github.com/DenisovAV/flutter_edge_ai/tree/main/packages/flutter_edge_ai/example).
