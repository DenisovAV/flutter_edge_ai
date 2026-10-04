import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'chat_page.dart';
import 'download_page.dart';
import 'model.dart';

/// Asks, for one model, whether it is already installed — and makes it the
/// active one either way.
///
/// `install()` is idempotent, so the bytes are only ever fetched once. What a
/// drifted id costs you is this gate: it answers "no" forever, so the app
/// shows the download screen on every launch, the "download" there finishes
/// instantly, and you land straight back here.
class ModelGate extends StatefulWidget {
  const ModelGate({super.key, required this.model});

  final ModelChoice model;

  @override
  State<ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends State<ModelGate> {
  late Future<bool> _installed = _check();

  /// Installed is not the same as active.
  ///
  /// This app puts three models in one container — two downloads and whatever
  /// you built in Step 4 — and `getActiveModel` opens whichever was installed
  /// LAST. So finding the file on disk is not enough: the gate has to say
  /// which model it means before the chat asks for one. `install()` is
  /// idempotent, so on a file already here it fetches nothing and only records
  /// this model as the current one.
  Future<bool> _check() async {
    if (!await FlutterEdgeAi.isModelInstalled(widget.model.fileName)) {
      return false;
    }
    await widget.model
        .locate(
          FlutterEdgeAi.installModel(
            modelType: widget.model.modelType,
            fileType: ModelFileType.litertlm,
          ),
        )
        .install();
    return true;
  }

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
          // screen as if nothing had gone wrong. Say what failed instead —
          // "External file does not exist" is what a moved or deleted tuned
          // model looks like, and it belongs on screen.
          return _GateError(
            error: snapshot.error!,
            onRetry: () => setState(() => _installed = _check()),
          );
        }
        if (snapshot.data ?? false) {
          return ChatPage(
            model: widget.model,
            // The model this route existed for is gone, so the route is too.
            onModelRemoved: () => Navigator.of(context).pop(),
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
      appBar: AppBar(),
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
