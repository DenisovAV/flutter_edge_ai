# flutter_gemma_litertlm example

`flutter_gemma_litertlm` is an opt-in inference engine for
[`flutter_gemma`](https://pub.dev/packages/flutter_gemma). It runs `.litertlm`
models via dart:ffi on the 5 native platforms (and via `@litert-lm/core` on
web). Register the engine once at startup, then use the unchanged inference API.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opt into the LiteRT-LM engine (handles ModelFileType.litertlm).
  await FlutterGemma.initialize(
    inferenceEngines: [LiteRtLmEngine()],
  );

  // Install a .litertlm model (downloads + sets it active).
  await FlutterGemma.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromNetwork('https://example.com/gemma3-1b-it.litertlm').install();

  // Create a model + session and generate.
  final model = await FlutterGemma.getActiveModel(maxTokens: 1024);
  final session = await model.createSession();
  await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
  final reply = await session.getResponse();
  print(reply);

  await session.close();
  await model.close();
}
```

Pass `LiteRtLmEngine()` alongside other engines (e.g. `MediaPipeEngine` from
`flutter_gemma_mediapipe`) if your app uses both `.litertlm` and `.task` models.
Web inference is an early preview — see the
[package README](https://pub.dev/packages/flutter_gemma_litertlm) for the
`web/index.html` handshake. A full runnable app lives in the
[`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example).

## Embeddings

As of 1.5.0 this package also ships the LiteRT C API embedding backend
(`LiteRtEmbeddingBackend`, Gecko / EmbeddingGemma `.tflite` — moved here from
`flutter_gemma_embeddings`, which now supplies the tokenizers this backend asks
core for):

```dart
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

await FlutterGemma.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
);
```
