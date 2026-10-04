import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import 'chat_page.dart';
import 'download_page.dart';
import 'model.dart';

const _model = Models.gemma4;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Engines are opt-in: the core registers none, and without LiteRtLmEngine
  // the first getActiveModel() throws a StateError telling you to add one.
  //
  // `WebStorageMode.streaming` is what the size demands on web: Gemma 4 E2B's
  // web build is 2.0 GB, right on the ~2 GB blob ceiling the default cacheApi
  // mode would have to buffer it into, so the @litert-lm/core engine reads it
  // from OPFS via a ReadableStream. Native platforms ignore this option.
  await FlutterEdgeAi.initialize(
    webStorageMode: WebStorageMode.streaming,
    inferenceEngines: [LiteRtLmEngine()],
  );

  runApp(const SkillsApp());
}

class SkillsApp extends StatelessWidget {
  const SkillsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge AI Skills',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const ModelGate(model: _model),
    );
  }
}

/// Opens on the chat when the model is already on the device, and on the
/// download screen when it is not.
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

  void _recheck() => setState(() => _installed = _check());

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
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snapshot.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _recheck,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.data ?? false) {
          return ChatPage(model: widget.model, onModelRemoved: _recheck);
        }
        return DownloadPage(model: widget.model, onInstalled: _recheck);
      },
    );
  }
}
