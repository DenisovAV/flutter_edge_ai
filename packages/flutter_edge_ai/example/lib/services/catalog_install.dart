import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The active model core's refusal names: an install would write over a file
/// it reads. Read from the refusal's message, whose words core holds with a
/// test (`activeFileRefusal` in its `catalog_entries_test.dart`).
final class ActiveModelInTheWay {
  const ActiveModelInTheWay({
    required this.kind,
    required this.name,
    this.inferenceFile,
  });

  /// `inference`, `embedding`, `speech-to-text` or `text-to-speech`.
  final String kind;

  /// The model's name, as the message gives it.
  final String name;

  /// The file `FlutterEdgeAi.uninstallModel` takes, for an inference model.
  final String? inferenceFile;

  static final _refusal = RegExp(
    r'over the file the active '
    r'(inference|embedding|speech-to-text|text-to-speech) model (.+) reads, '
    r'and checks it only afterwards\. Uninstall that model first '
    r"\(FlutterEdgeAi\.(?:uninstallModel\('([^']+)'\)|uninstall\w+\(\))\)",
  );

  /// The model [error] names, or null when it is another error.
  static ActiveModelInTheWay? of(StateError error) {
    final match = _refusal.firstMatch(error.message);
    if (match == null) return null;
    return ActiveModelInTheWay(
      kind: match[1]!,
      name: match[2]!,
      inferenceFile: match[3],
    );
  }

  /// Uninstalls it with the call of its kind.
  Future<void> uninstall() => switch (kind) {
    'embedding' => FlutterEdgeAi.uninstallEmbedder(),
    'speech-to-text' => FlutterEdgeAi.uninstallStt(),
    'text-to-speech' => FlutterEdgeAi.uninstallTts(),
    _ => FlutterEdgeAi.uninstallModel(inferenceFile!),
  };
}

/// Runs [install], a catalog install of [variant]. Core refuses one that
/// would write over a file an active model of any kind reads — a model
/// installed earlier under the catalog's name from another source
/// (`/resolve/main/`, an older pin) — so that file is never left wrong under a
/// model in use. The example then asks the user, with [confirm], whether to
/// replace that model (its name and the download's size); on yes it
/// uninstalls that model with [uninstall] and installs again, on no the
/// refusal is the caller's to show.
Future<T> installFromCatalogReplacingActive<T>(
  Future<T> Function() install, {
  required CatalogVariant variant,
  required Future<bool> Function(ActiveModelInTheWay model, int downloadBytes)
  confirm,
  Future<void> Function(ActiveModelInTheWay model)? uninstall,
}) async {
  try {
    return await install();
  } on StateError catch (e) {
    final model = ActiveModelInTheWay.of(e);
    if (model == null) rethrow;
    final bytes = variant.files.fold(0, (sum, f) => sum + f.sizeBytes);
    if (!await confirm(model, bytes)) rethrow;
    await (uninstall ?? (m) => m.uninstall())(model);
    return install();
  }
}

/// The question [installFromCatalogReplacingActive] asks, as a dialog over
/// [context]. False when the user says no, or the dialog is dismissed.
Future<bool> askToReplaceActiveModel(
  BuildContext context,
  ActiveModelInTheWay model,
  int downloadBytes,
) async {
  if (!context.mounted) return false;
  final size = downloadBytes >= 1000000000
      ? '${(downloadBytes / 1000000000).toStringAsFixed(1)} GB'
      : '${(downloadBytes / 1000000).ceil()} MB';
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Replace the installed model?'),
      content: Text(
        'The active ${model.kind} model ${model.name} uses a file this build '
        'installs under the same name. Replacing it uninstalls '
        '${model.name} and downloads $size.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep it'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Replace'),
        ),
      ],
    ),
  );
  return answer ?? false;
}
