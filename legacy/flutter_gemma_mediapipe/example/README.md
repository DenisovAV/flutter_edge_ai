# flutter_gemma_mediapipe example

`flutter_gemma_mediapipe` is an opt-in inference engine for
[`flutter_gemma`](https://pub.dev/packages/flutter_gemma). It runs MediaPipe
`.task` / `.bin` models on Android, iOS, and Web. Register the engine once at
startup, then use the unchanged inference API.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opt into the MediaPipe engine (handles ModelFileType.task / .bin).
  await FlutterGemma.initialize(
    inferenceEngines: [MediaPipeEngine()],
  );

  // Install a .task model (downloads + sets it active).
  await FlutterGemma.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
  ).fromNetwork('https://example.com/gemma3-1b-it.task').install();

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

Pass `MediaPipeEngine()` alongside other engines (e.g. `LiteRtLmEngine` from
`flutter_gemma_litertlm`) if your app uses both `.task` and `.litertlm` models.
On web the MediaPipe runtime loads from a CDN — see the
[package README](https://pub.dev/packages/flutter_gemma_mediapipe) for the
`web/index.html` setup. A full runnable app lives in the
[`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example).
