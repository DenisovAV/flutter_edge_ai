import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/utils/gated_model_access_dialog.dart';
import 'package:flutter_edge_ai_example/utils/storage_quota_dialog.dart';

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
    r"\(FlutterEdgeAi\.(?:uninstallModel\('((?:[^'\\]|\\.)+)'\)|uninstall\w+\(\))\)",
  );

  /// The model [error] names, or null when it is another error.
  static ActiveModelInTheWay? of(StateError error) {
    final match = _refusal.firstMatch(error.message);
    if (match == null) return null;
    return ActiveModelInTheWay(
      kind: match[1]!,
      name: match[2]!,
      // Quoted as a Dart string: `\'` and `\\` are escapes.
      inferenceFile: match[3]?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!),
    );
  }

  /// The core call that uninstalls it, by its kind: a static tear-off for
  /// the embedder, STT and TTS (so a test can compare it), and
  /// `uninstallModel` with its file for an inference model.
  Future<void> Function() get uninstaller => switch (kind) {
    'embedding' => FlutterEdgeAi.uninstallEmbedder,
    'speech-to-text' => FlutterEdgeAi.uninstallStt,
    'text-to-speech' => FlutterEdgeAi.uninstallTts,
    _ => () => FlutterEdgeAi.uninstallModel(inferenceFile!),
  };

  /// Uninstalls it with the call of its kind.
  Future<void> uninstall() => uninstaller();
}

/// How [installFromCatalogReplacingActive] ended without an error.
sealed class CatalogInstallResult {
  const CatalogInstallResult();
}

/// The build is installed.
final class CatalogInstalled extends CatalogInstallResult {
  const CatalogInstalled();
}

/// The user kept [model]: nothing was uninstalled or downloaded. Not an
/// error; [message] says so in words for the user.
final class CatalogInstallKept extends CatalogInstallResult {
  const CatalogInstallKept(this.model);

  final ActiveModelInTheWay model;

  String get message =>
      'Kept ${model.name}. Nothing was uninstalled or downloaded.';
}

/// The user agreed to replace a model and something after that failed:
/// [message] says which models are already gone.
final class CatalogReplaceFailed implements Exception {
  const CatalogReplaceFailed(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Runs [install], a catalog install of [variant]. Core refuses one that
/// would write over a file an active model of any kind reads — a model
/// installed earlier under the catalog's name from another source
/// (`/resolve/main/`, an older pin) — so that file is never left wrong under a
/// model in use. The example then asks the user, with [confirm], whether to
/// replace that model (its name and the download's size):
///
/// - "keep it" is [CatalogInstallKept], not an error;
/// - on "replace" it uninstalls that model with [uninstall] and installs
///   again, asking again for each further model in the way;
/// - a failure after a model was uninstalled is [CatalogReplaceFailed],
///   whose message names what is already gone; one before that is the
///   install's own error.
Future<CatalogInstallResult> installFromCatalogReplacingActive(
  Future<void> Function() install, {
  required CatalogVariant variant,
  required Future<bool> Function(ActiveModelInTheWay model, int downloadBytes)
  confirm,
  Future<void> Function(ActiveModelInTheWay model)? uninstall,
}) async {
  final bytes = variant.files.fold(0, (sum, f) => sum + f.sizeBytes);
  // By kind and name: an inference model and an embedder may share a name.
  final removed = <(String, String)>[];
  String gone() =>
      '${removed.map((m) => m.$2).join(' and ')} '
      '${removed.length == 1 ? 'was' : 'were'} already uninstalled';
  Never failAfterRemoval(Object error, StackTrace stack) {
    if (removed.isEmpty) Error.throwWithStackTrace(error, stack);
    throw CatalogReplaceFailed(
      '${gone()}, but ${variant.id} did not install: $error. Install it '
      'again.',
      error,
    );
  }

  while (true) {
    final ActiveModelInTheWay inTheWay;
    try {
      await install();
      return const CatalogInstalled();
    } on StateError catch (e, stack) {
      final model = ActiveModelInTheWay.of(e);
      if (model == null) failAfterRemoval(e, stack);
      if (removed.contains((model.kind, model.name))) {
        // The same model again: its uninstall did not release the file.
        throw CatalogReplaceFailed(
          'Uninstalling ${model.name} did not release its file, so '
          '${variant.id} is not installed${removed.length > 1 ? '; ${gone()}' : ''}.',
          e,
        );
      }
      inTheWay = model;
    } catch (e, stack) {
      failAfterRemoval(e, stack);
    }
    if (!await confirm(inTheWay, bytes)) {
      if (removed.isEmpty) return CatalogInstallKept(inTheWay);
      throw CatalogReplaceFailed(
        '${gone()}; ${inTheWay.name} was kept, so ${variant.id} is not '
        'installed.',
      );
    }
    try {
      await (uninstall ?? (m) => m.uninstall())(inTheWay);
    } catch (e) {
      throw CatalogReplaceFailed(
        'Could not uninstall ${inTheWay.name} ($e); it may be partly '
        'removed${removed.isEmpty ? '' : ', and ${gone()}'}. Nothing was '
        'downloaded.',
        e,
      );
    }
    removed.add((inTheWay.kind, inTheWay.name));
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
        '${model.name} and downloads up to $size.',
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

/// Leaves a screen that needed the new build after the user kept the old
/// model: says so, neutrally, and goes back.
void leaveKeeping(BuildContext context, CatalogInstallKept kept) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(kept.message)));
  Navigator.maybePop(context);
}

/// One thing a download screen shows for a failed install, in the order of
/// [installErrorViews].
sealed class InstallErrorView {
  const InstallErrorView();
}

/// A message: what a failed replace left behind, or the screen's own text.
final class InstallErrorMessage extends InstallErrorView {
  const InstallErrorMessage(this.text);

  final String text;
}

/// The gated-access dialog, for [error].
final class InstallErrorGated extends InstallErrorView {
  const InstallErrorGated(this.error);

  final Object error;
}

/// The not-enough-storage dialog.
final class InstallErrorStorage extends InstallErrorView {
  const InstallErrorStorage();
}

/// What a download screen shows for [error], in order. A failed replace says
/// first that the old model is already gone, then offers the dialog its cause
/// needs (an expired token, a full disk): the dialog alone would hide what was
/// uninstalled. Anything else is the gated or storage dialog, or [fallback].
List<InstallErrorView> installErrorViews(
  Object error, {
  required String fallback,
}) {
  InstallErrorView? dialogFor(Object e) => isGatedAccessError(e)
      ? InstallErrorGated(e)
      : isStorageQuotaError(e)
      ? const InstallErrorStorage()
      : null;
  if (error is CatalogReplaceFailed) {
    final cause = error.cause;
    return [
      InstallErrorMessage(error.message),
      if (cause != null) ?dialogFor(cause),
    ];
  }
  return [dialogFor(error) ?? InstallErrorMessage(fallback)];
}
