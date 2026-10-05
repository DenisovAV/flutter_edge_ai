import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Web build of the embedded [WebviewResult] renderer.
///
/// `flutter_inappwebview`'s web arm has no JS bridge and we never import it on
/// web; instead this arm embeds the skill's page in a plain `<iframe>`
/// ([web.HTMLIFrameElement]) surfaced through [HtmlElementView]. The mirror
/// native arm (`webview_widget_io.dart`) renders an `InAppWebView`. Both export
/// the same [buildInlineWebview] signature behind the `webview_widget.dart`
/// conditional-export seam.
Widget buildInlineWebview(String url, {double aspectRatio = 4 / 3}) {
  // A stable per-url view type so two distinct webview results don't collide and
  // re-registering the same url is idempotent (registerViewFactory is a no-op
  // for an already-registered type).
  final viewType = 'flutter_gemma_agent.webview/$url';
  if (!_registered.contains(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      return web.HTMLIFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
    });
    _registered.add(viewType);
  }
  return AspectRatio(
    aspectRatio: aspectRatio,
    child: HtmlElementView(viewType: viewType),
  );
}

/// View types already registered this session — `registerViewFactory` throws if
/// called twice for the same type, so we guard against re-registration.
final Set<String> _registered = <String>{};
