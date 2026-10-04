import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import 'models_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Engines are fully opt-in: the core package registers none by itself.
  // Without LiteRtLmEngine here, the first model call throws a StateError
  // that tells you to add an engine package.
  //
  // No `huggingFaceToken:` — both repositories this app downloads from are
  // ungated, so every `flutter run` is a plain `flutter run` with no
  // `--dart-define`.
  //
  // Guarded, because every other failure in this app reaches the screen — the
  // gate's error card, the chat's load error, the notice line — and this is the
  // earliest one, so it is the one a learner meets first. Hot-restarting after
  // adding a plugin throws `MissingPluginException` right here; unguarded, it
  // never reaches `runApp` and the symptom is a blank window and a stack trace
  // in a console nobody is looking at.
  try {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      // OPFS streaming: on web a `.litertlm` this size does not fit the blob
      // the default `cacheApi` mode would have to buffer it into. Every other
      // platform ignores this.
      webStorageMode: WebStorageMode.streaming,
    );
  } catch (error) {
    runApp(_StartupFailed(error: error));
    return;
  }

  runApp(const FunctionCallingApp());
}

/// Shown in place of the app when `FlutterEdgeAi.initialize` throws, so a
/// failure before the first frame is a sentence instead of a blank window.
class _StartupFailed extends StatelessWidget {
  const _StartupFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma Function Calling',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'flutter_edge_ai could not start.\n$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class FunctionCallingApp extends StatelessWidget {
  const FunctionCallingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma Function Calling',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const ModelsPage(),
    );
  }
}
