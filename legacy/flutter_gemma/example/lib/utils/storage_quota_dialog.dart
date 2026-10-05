import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/downloaded_models_screen.dart';

/// Returns true when the download failed because the browser/device ran out of
/// storage (OPFS / Cache API quota). Web models are ~2 GB each, so a few
/// downloads can fill the per-origin quota.
bool isStorageQuotaError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('quota') ||
      message.contains('quotaexceeded') ||
      message.contains('exceed its storage') ||
      message.contains('not enough space') ||
      message.contains('no space left');
}

/// Shows a clear "not enough space" dialog with a button that opens the
/// downloaded-models screen so the user can free space by deleting models.
Future<void> showStorageFullDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Not enough storage'),
      content: const Text(
        'There isn\'t enough space to download this model. On-device models are '
        'large (~2 GB each). Free up space by deleting models you no longer '
        'need, then try again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DownloadedModelsScreen(),
              ),
            );
          },
          child: const Text('Manage models'),
        ),
      ],
    ),
  );
}
