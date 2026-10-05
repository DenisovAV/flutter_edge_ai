# flutter_gemma_embeddings example

`flutter_gemma_embeddings` is the runtime-agnostic on-device text-embedding
*pipeline* for [`flutter_gemma`](https://pub.dev/packages/flutter_gemma) —
tokenization, the background-isolate worker, and pooling/normalization, over
an `EmbeddingForwardPass` seam. It does not ship a concrete backend itself
(since 2.0.0); pair it with an engine package that provides one, e.g.
[`flutter_gemma_litertlm`](https://pub.dev/packages/flutter_gemma_litertlm)'s
`LiteRtEmbeddingBackend` (Gecko / EmbeddingGemma `.tflite` via the LiteRT C
API — dart:ffi on the 5 native platforms, LiteRT.js on web). Register the
backend once at startup, then embed text and feed the vectors into any RAG
vector store.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The backend comes from an engine package; the tokenizers from this one.
  await FlutterGemma.initialize(
    embeddingBackends: [LiteRtEmbeddingBackend()],   // flutter_gemma_litertlm
    embeddingTokenizers: [GemmaEmbeddingTokenizers()],
  );

  // Install an embedding model (downloads + sets it active). The model and its
  // tokenizer are separate downloads.
  await FlutterGemma.installEmbedder()
      .modelFromNetwork('https://example.com/embeddinggemma.tflite', token: 'hf_...')
      .tokenizerFromNetwork('https://example.com/sentencepiece.model', token: 'hf_...')
      .install();

  // Create the embedding model and embed text.
  final embedder = await FlutterGemma.getActiveEmbedder();
  final vector = await embedder.generateEmbedding('Gemma runs on-device.');
  print('embedding dim: ${vector.length}');

  await embedder.close();
}
```

Pair this with a RAG vector store (`flutter_gemma_rag_qdrant` on native,
`flutter_gemma_rag_sqlite` for web) to build on-device retrieval. A full runnable
app lives in the
[`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example).
