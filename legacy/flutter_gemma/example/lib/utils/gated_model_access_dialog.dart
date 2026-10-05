import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:url_launcher/url_launcher.dart';

final _accessToModelPattern = RegExp(
  r'Access to model ([\w.-]+/[\w.-]+)',
  caseSensitive: false,
);

Object? _exceptionCause(Object error) {
  try {
    final dynamic exception = error;
    final cause = exception.cause;
    if (cause is Object) return cause;
  } catch (_) {}
  return null;
}

/// Returns true when the download failed due to missing/invalid HF auth or
/// gated-repo access (HTTP 401/403).
bool isGatedAccessError(Object error) {
  Object? current = error;
  final seen = <int>{};

  while (current != null) {
    final identity = identityHashCode(current);
    if (!seen.add(identity)) break;

    if (current is DownloadException) {
      return switch (current.error) {
        UnauthorizedError() || ForbiddenError() => true,
        _ => false,
      };
    }

    final cause = _exceptionCause(current);
    if (cause != null) {
      current = cause;
      continue;
    }

    break;
  }

  final message = error.toString().toLowerCase();
  final hasAuthStatus =
      message.contains('401') ||
      message.contains('403') ||
      message.contains('unauthorized');
  final looksGated =
      message.contains('restricted') ||
      message.contains('authenticated') ||
      message.contains('access denied') ||
      message.contains('authentication failed') ||
      message.contains('access forbidden');
  return hasAuthStatus && looksGated;
}

/// Resolves the Hugging Face model repo page for [modelUrl] and [error].
String huggingFaceModelPageUrl({
  required String modelUrl,
  String? licenseUrl,
  Object? error,
}) {
  final fromUrl = _repoPageFromHuggingFaceUrl(modelUrl);
  if (fromUrl != null) return fromUrl;

  if (error != null) {
    final match = _accessToModelPattern.firstMatch(error.toString());
    if (match != null) {
      return 'https://huggingface.co/${match.group(1)}';
    }
  }

  if (licenseUrl != null && licenseUrl.isNotEmpty) {
    return licenseUrl;
  }

  return 'https://huggingface.co/settings/tokens';
}

String? _repoPageFromHuggingFaceUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (!uri.host.contains('huggingface.co')) return null;
    if (uri.pathSegments.length < 2) return null;

    final org = uri.pathSegments[0];
    final repo = uri.pathSegments[1];
    if (org == 'resolve' || org == 'api' || org == 'datasets') return null;
    return 'https://huggingface.co/$org/$repo';
  } catch (_) {
    return null;
  }
}

bool _isForbidden(Object error) {
  Object? current = error;
  final seen = <int>{};

  while (current != null) {
    final identity = identityHashCode(current);
    if (!seen.add(identity)) break;

    if (current is DownloadException) {
      return current.error is ForbiddenError;
    }

    final cause = _exceptionCause(current);
    if (cause != null) {
      current = cause;
      continue;
    }

    break;
  }

  final message = error.toString().toLowerCase();
  return message.contains('403') ||
      message.contains('forbidden') ||
      message.contains('access denied');
}

/// Shows a dialog explaining gated-model access with a link to the HF repo page.
Future<void> showGatedModelAccessDialog({
  required BuildContext context,
  required String modelUrl,
  String? licenseUrl,
  required Object error,
}) {
  final modelPageUrl = huggingFaceModelPageUrl(
    modelUrl: modelUrl,
    licenseUrl: licenseUrl,
    error: error,
  );
  final isForbidden = _isForbidden(error);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        isForbidden ? 'Model access required' : 'Authentication required',
      ),
      content: Text(
        isForbidden
            ? 'This model is gated on Hugging Face. Open the model page, sign in, '
                  'accept the license if prompted, and request access. Then retry the '
                  'download with a token that has read access to the repository.'
            : 'Download failed because Hugging Face rejected the request. Save a valid '
                  'access token with read-repo permission, accept the model license on '
                  'Hugging Face if required, then try again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final uri = Uri.parse(modelPageUrl);
            var launched = false;
            try {
              if (await canLaunchUrl(uri)) {
                launched = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
              }
            } catch (_) {
              launched = false;
            }
            if (!launched) {
              await Clipboard.setData(ClipboardData(text: modelPageUrl));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not open browser. URL copied to clipboard.',
                    ),
                  ),
                );
              }
            }
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext);
            }
          },
          child: const Text('Open on Hugging Face'),
        ),
      ],
    ),
  );
}
