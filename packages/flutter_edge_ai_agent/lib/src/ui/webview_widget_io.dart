import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Native (`dart:io`) build of the embedded [WebviewResult] renderer.
///
/// `flutter_inappwebview` has a platform implementation on Android, iOS, macOS
/// and Windows, so an inline [InAppWebView] renders the skill's page in-tree.
/// The plugin is imported ONLY through this conditional-export seam (this file
/// on native, `webview_widget_web.dart` on web) so the web build never pulls the
/// plugin's web arm (which has no JS bridge). The caller gates this on a
/// supported platform; on an unsupported native target it shows the external
/// "Open" card instead of reaching here.
///
/// A [WebviewResult] with `iframe: true` means "embed this URL as a NESTED
/// document" — the web arm does exactly that with `<iframe src=url>`. Loading
/// the URL directly as the webview's top document (what `initialUrlRequest`
/// does) breaks embed-only content: e.g. the Google Maps Embed the
/// interactive-map skill returns detects `window.top === window.self` and
/// refuses with "must be used in an iframe". So we mirror the web arm and load
/// an HTML shell whose only child is an `<iframe src=url>`, giving the embedded
/// page the nested context it expects on native too.
Widget buildInlineWebview(String url, {double aspectRatio = 4 / 3}) {
  return AspectRatio(
    aspectRatio: aspectRatio,
    child: InAppWebView(
      initialData: InAppWebViewInitialData(
        data: iframeShellHtml(url),
        baseUrl: WebUri(url),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
    ),
  );
}

/// The HTML shell that embeds [url] in a full-bleed `<iframe>` (the nested
/// context embed-only pages like Google Maps require). PURE (no webview) so it
/// is host-testable. [url] is HTML-attribute-escaped so it can't break out of
/// the `src="…"` attribute.
String iframeShellHtml(String url) {
  final safeUrl = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
  return '<!DOCTYPE html><html><head>'
      '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
      '<style>html,body{margin:0;height:100%}'
      'iframe{border:0;width:100%;height:100%}</style></head>'
      '<body><iframe src="$safeUrl" '
      'allow="geolocation; fullscreen"></iframe></body></html>';
}
