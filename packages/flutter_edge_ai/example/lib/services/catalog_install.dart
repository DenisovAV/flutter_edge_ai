import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/utils/gated_model_access_dialog.dart';
import 'package:flutter_edge_ai_example/utils/storage_quota_dialog.dart';

/// The active model core's refusal names: an install would write over a file
/// it reads. Read from the refusal's message, whose words core holds in a
/// golden file (`test/catalog/active_file_refusals.golden.txt`) that this
/// app's test parses too.
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
    r"\(FlutterEdgeAi\.(uninstall\w+)\((?:'((?:[^'\\]|\\.)+)')?\)\)",
  );

  /// The call core names for each kind, and whether it takes the file.
  static const _calls = {
    'inference': ('uninstallModel', true),
    'embedding': ('uninstallEmbedder', false),
    'speech-to-text': ('uninstallStt', false),
    'text-to-speech': ('uninstallTts', false),
  };

  /// The model [error] names, or null when it is another error, or one whose
  /// call does not fit its kind (a wording this app does not know).
  static ActiveModelInTheWay? of(StateError error) {
    final match = _refusal.firstMatch(error.message);
    if (match == null) return null;
    final kind = match[1]!;
    final (call, takesFile) = _calls[kind]!;
    final file = match[4];
    if (match[3] != call || (file != null) != takesFile) return null;
    return ActiveModelInTheWay(
      kind: kind,
      name: match[2]!,
      // Quoted as a Dart string: `\'` and `\\` are escapes.
      inferenceFile: file?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!),
    );
  }

  /// The core call that uninstalls it, by its kind, as a static tear-off a
  /// test can compare: `uninstallModel` (given [inferenceFile]) for an
  /// inference model, the kind's own call for the others.
  Function get uninstaller => switch (kind) {
    'embedding' => FlutterEdgeAi.uninstallEmbedder,
    'speech-to-text' => FlutterEdgeAi.uninstallStt,
    'text-to-speech' => FlutterEdgeAi.uninstallTts,
    _ => FlutterEdgeAi.uninstallModel,
  };

  /// Uninstalls it with the call of its kind: [uninstaller], or [via] in
  /// tests, which then receives what core's call would.
  Future<void> uninstall({Function? via}) => switch (via ?? uninstaller) {
    final Future<void> Function(String) byFile => byFile(inferenceFile!),
    final Future<void> Function() call => call(),
    _ => throw StateError('no uninstall call for a $kind model'),
  };
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

  /// The models already uninstalled, but for [except].
  String gone({(String, String)? except}) {
    final names = [
      for (final m in removed)
        if (m != except) m.$2,
    ];
    return '${names.join(' and ')} ${names.length == 1 ? 'was' : 'were'} '
        'already uninstalled';
  }

  // The failure's own stack goes with the wrapper that names what is gone.
  Never failAfterRemoval(Object error, StackTrace stack) {
    if (removed.isEmpty) Error.throwWithStackTrace(error, stack);
    Error.throwWithStackTrace(
      CatalogReplaceFailed(
        '${gone()}, but ${variant.id} did not install: $error. Install it '
        'again.',
        error,
      ),
      stack,
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
      final key = (model.kind, model.name);
      if (removed.contains(key)) {
        // The same model again: its uninstall did not release the file.
        Error.throwWithStackTrace(
          CatalogReplaceFailed(
            'Uninstalling ${model.name} did not release its file, so '
            '${variant.id} is not installed'
            '${removed.length > 1 ? '; ${gone(except: key)}' : ''}.',
            e,
          ),
          stack,
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
    } catch (e, stack) {
      Error.throwWithStackTrace(
        CatalogReplaceFailed(
          'Could not uninstall ${inTheWay.name} ($e); it may be partly '
          'removed${removed.isEmpty ? '' : ', and ${gone()}'}. Nothing was '
          'downloaded.',
          e,
        ),
        stack,
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

/// Shows what [error] needs ([installErrorViews] with [fallback]) over
/// [context], one after the other, each awaited: a message as a dialog (a
/// snackbar's time would run out behind the next dialog's barrier, and with
/// it "already uninstalled"), then the gated dialog ([gated]) or the storage
/// one.
///
/// The error and its [stack] are logged ([log], `debugPrint` by default)
/// first, so a screen that is already gone (the user backed out during a long
/// download) still leaves "already uninstalled" somewhere.
Future<void> showInstallErrors(
  BuildContext context,
  Object error,
  StackTrace stack, {
  required String fallback,
  required Future<void> Function(Object error) gated,
  void Function(String line)? log,
}) async {
  (log ?? (line) => debugPrint(line))('Model install failed: $error\n$stack');
  for (final view in installErrorViews(error, fallback: fallback)) {
    if (!context.mounted) return;
    switch (view) {
      case InstallErrorMessage(:final text):
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Download error'),
            content: Text(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      case InstallErrorGated(:final error):
        await gated(error);
      case InstallErrorStorage():
        await showStorageFullDialog(context);
    }
  }
}
