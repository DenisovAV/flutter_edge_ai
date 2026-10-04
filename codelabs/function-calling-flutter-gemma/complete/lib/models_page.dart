import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';
import 'model_gate.dart';

/// The list of models this app can open.
///
/// Two it can download, and any others it finds already installed — which is
/// how the model you fine-tuned in Step 4 turns up here after the first time
/// you point the app at it. Nothing below treats it as a special case: it is a
/// `.litertlm`, and the chat opens it exactly like the other two.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late Future<List<ModelChoice>> _yours = _findYourOwn();

  /// Everything installed that this app did not ship a constant for.
  ///
  /// `listInstalledModels` returns the ids — which are file names — and
  /// `getModelPath` turns one back into where the file actually is. For a
  /// model installed from disk that is the original path, not a copy: the
  /// install registered the file where it lay.
  Future<List<ModelChoice>> _findYourOwn() async {
    final shipped = {for (final m in Models.downloadable) m.fileName};
    final installed = await FlutterEdgeAi.listInstalledModels();
    final yours = <ModelChoice>[];
    for (final id in installed) {
      if (shipped.contains(id)) continue;
      yours.add(ModelChoice.fromDisk(await FlutterEdgeAi.getModelPath(id)));
    }
    return yours;
  }

  Future<void> _open(ModelChoice model) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ModelGate(model: model)));
    // A model may have been installed or deleted behind that route.
    if (mounted) setState(() => _yours = _findYourOwn());
  }

  /// Asks for a path rather than opening a file picker.
  ///
  /// The file this is for was written by a command line — `litetune convert`
  /// prints where it put it — so the path is already on the learner's screen,
  /// and a picker would be a sixth dependency to avoid retyping it.
  Future<void> _addFromDisk() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open a .litertlm from disk'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The absolute path to the file. Nothing is copied — the app '
              'records where the file is, so moving or deleting it later '
              'takes the model with it.\n\n'
              'On macOS this app is sandboxed: a path under ~/Downloads is '
              'not readable from inside it. Copy the file into the app\'s '
              'own Documents directory and paste that path.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText:
                    '…/Containers/dev.fluttergemma.functioncalling/Data/Documents/model.litertlm',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path == null || path.isEmpty || !mounted) return;
    await _open(ModelChoice.fromDisk(path));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: FutureBuilder<List<ModelChoice>>(
        future: _yours,
        builder: (context, snapshot) {
          final yours = snapshot.data ?? const <ModelChoice>[];
          return ListView(
            children: [
              for (final model in Models.downloadable)
                _ModelTile(model: model, onTap: () => _open(model)),
              if (yours.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
                  child: Text(
                    'Your own models',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final model in yours)
                  _ModelTile(model: model, onTap: () => _open(model)),
              ],
              const Divider(height: 32),
              if (kIsWeb)
                // `fromFile` on the web has no filesystem to read: the browser
                // arm registers a URL, not a path. Saying so beats a text
                // field that cannot work.
                const ListTile(
                  leading: Icon(Icons.folder_off_outlined),
                  title: Text('Opening a file from disk needs a native build'),
                  subtitle: Text(
                    'A browser has no path to give. Run this app on a desktop '
                    'or a phone to try the model you tuned in Step 4.',
                  ),
                )
              else
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('Open a .litertlm from disk'),
                  subtitle: const Text(
                    'The file Step 4 produced — or any other .litertlm.',
                  ),
                  onTap: _addFromDisk,
                ),
              if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Could not read what is installed: ${snapshot.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model, required this.onTap});

  final ModelChoice model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final abilities = [
      if (model.supportsThinking) 'thinking' else 'no thinking',
      if (model.supportsRequiredToolChoice)
        'can be forced to call'
      else
        'auto only',
    ].join(' · ');

    return ListTile(
      title: Text(model.label),
      subtitle: Text('${model.sizeLabel} — $abilities'),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
