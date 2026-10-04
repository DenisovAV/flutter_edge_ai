import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../skill_result.dart';
// Conditional-export seam for the embedded webview widget: the native arm
// (flutter_inappwebview `InAppWebView`) is reached on every native target, the
// `package:web` `<iframe>` arm on web. `flutter_inappwebview` is imported ONLY
// by `webview_widget_io.dart` so the web build never pulls the plugin's broken
// web arm (mirrors the JS-runtime split).
import 'webview_widget.dart';

/// Renders a [SkillResult] inline — the one place that turns the sealed result
/// variants into widgets, reused by the chat view and the skill tester.
///
/// * [TextResult]   → selectable text.
/// * [ImageResult]  → the decoded image.
/// * [WidgetResult] → the native widget verbatim (our cross-platform edge).
/// * [WebviewResult]→ an inline webview (native `InAppWebView` / web `<iframe>`)
///   when [iframe] (and a webview platform is available), else an "Open" card.
/// * [ErrorResult]  → an error banner.
class SkillResultView extends StatelessWidget {
  const SkillResultView({
    super.key,
    required this.result,
    this.maxImageHeight = 240,
    this.webviewAspectRatio = 4 / 3,
  });

  /// The structured result to render.
  final SkillResult result;

  /// Cap on an inline image's height.
  final double maxImageHeight;

  /// Aspect ratio for an embedded webview.
  final double webviewAspectRatio;

  @override
  Widget build(BuildContext context) {
    return switch (result) {
      TextResult(:final text) => SelectableText(text),
      ImageResult(:final bytes) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          height: maxImageHeight,
          errorBuilder: (_, _, _) => const _ResultError('Could not show image'),
        ),
      ),
      WidgetResult(:final widget) => widget,
      WebviewResult(:final url, :final iframe) => _Webview(
        url: url,
        iframe: iframe,
        aspectRatio: webviewAspectRatio,
      ),
      ErrorResult(:final message) => _ResultError(message),
    };
  }
}

/// Whether an inline (embedded) webview can render on this platform.
/// `flutter_inappwebview` ships Android, iOS, macOS and Windows; the web arm
/// embeds an iframe. Linux has no implementation, so there we fall back to an
/// external "Open" card.
bool get _webviewEmbeddable {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
}

class _Webview extends StatelessWidget {
  const _Webview({
    required this.url,
    required this.iframe,
    required this.aspectRatio,
  });

  final String url;
  final bool iframe;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    // Embed the page in-tree only when the skill asked for it and this platform
    // has a webview implementation; otherwise (external webview, or an
    // unsupported platform like Linux) show a tappable "Open" card.
    if (!iframe || !_webviewEmbeddable) {
      return _OpenUrlCard(url: url);
    }
    // The conditional-export seam returns the native InAppWebView or the web
    // <iframe>, already wrapped to [aspectRatio].
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: buildInlineWebview(url, aspectRatio: aspectRatio),
    );
  }
}

class _OpenUrlCard extends StatelessWidget {
  const _OpenUrlCard({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.open_in_new),
        title: const Text('Open web page'),
        subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () async {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            await launcher.launchUrl(
              uri,
              mode: launcher.LaunchMode.externalApplication,
            );
          }
        },
      ),
    );
  }
}

class _ResultError extends StatelessWidget {
  const _ResultError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(message, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}
