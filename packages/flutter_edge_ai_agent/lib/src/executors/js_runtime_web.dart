import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

import 'js_skill_executor.dart';

/// The web ([dart:js_interop]) [JsRuntime] factory — selected by the conditional
/// export in `js_runtime.dart` when `dart.library.js_interop` is available. This
/// arm uses `package:web` only; it NEVER imports `flutter_inappwebview` (whose
/// web arm has no JS bridge), so the web build stays plugin-free.
JsRuntime createJsRuntime() => _WebIframeJsRuntime();

/// Web [JsRuntime] backed by a headless, sandboxed `<iframe>` (`package:web`).
///
/// The `flutter_inappwebview` web arm exposes neither `addJavaScriptHandler` nor
/// `callHandler`, so the native bridge is dead on web. Instead this runtime:
/// 1. Creates an off-tree [web.HTMLIFrameElement] with `sandbox = "allow-scripts"`
///    (scripts run, but the frame is a unique opaque origin — no same-origin
///    access, no top-navigation, no forms), the single-bridge sandbox.
/// 2. Loads the skill: `srcdoc` = the inline HTML (asset) or `src` = the skill
///    URL. Asset HTML is inlined exactly like the native arm (sibling `index.js`
///    spliced in) so a `<script src="index.js">` reference still runs.
/// 3. On the iframe `load` event, evals the web-variant injection script
///    ([buildInjectionScript] with `web: true`), which posts the JSON result via
///    `window.parent.postMessage({ handler: 'AiEdgeGallery', data }, origin)`.
/// 4. A `window` `message` listener (tagged by [resultChannel]) completes the
///    [Completer]; the iframe and listener are torn down in `finally`.
class _WebIframeJsRuntime implements JsRuntime {
  @override
  Future<String> run({
    required JsSkillSource source,
    required String dataJson,
    required String secret,
    required Duration timeout,
  }) async {
    final completer = Completer<String>();

    final iframe = web.HTMLIFrameElement()
      ..style.display = 'none'
      ..setAttribute('sandbox', 'allow-scripts')
      ..setAttribute('aria-hidden', 'true');

    // The web-variant injection script: same Gallery contract, but OUR wrapper
    // posts the result back through window.parent.postMessage.
    final injection = buildInjectionScript(dataJson, secret, web: true);

    switch (source) {
      case AssetJsSource(:final assetKey):
        final html = await rootBundle.loadString(assetKey);
        final js = await _loadSiblingJs(assetKey, html);
        // Splice the sibling index.js inline, then append our injection so it
        // runs after the skill defines its global (mirrors the native onLoadStop
        // evaluateJavascript, but baked into the document for the sandboxed
        // opaque-origin frame, which we cannot reach into post-load).
        final inlined = inlineSkillHtml(html, js);
        iframe.srcdoc = '$inlined<script>$injection</script>'.toJS;
      case UrlJsSource(:final url) when url.startsWith('data:'):
        // A `data:text/html` skill: decode the HTML and bake it into srcdoc with
        // the injection appended (same as the asset path). A sandboxed iframe has
        // an opaque origin the parent CANNOT reach into post-load, so loading via
        // `src` + a later `contentWindow.eval` silently fails (cross-origin); the
        // injection must be part of the document.
        final html = _decodeDataUrlHtml(url);
        iframe.srcdoc = '$html<script>$injection</script>'.toJS;
      case UrlJsSource(:final url):
        // Remote http(s) skills: load the page; a cross-origin/sandboxed frame is
        // unreachable from the parent, so the page must post back itself.
        iframe.src = url;
    }

    // The single bridge: only messages tagged with [resultChannel] from our own
    // iframe complete the result. A sandboxed (allow-scripts only) iframe has an
    // opaque origin, so we cannot match event.origin to a known value — we gate
    // on the handler tag instead.
    final onMessage = (web.Event event) {
      if (!event.isA<web.MessageEvent>()) return;
      final data = (event as web.MessageEvent).data;
      if (data == null || !data.isA<JSObject>()) return;
      // Our wrapper posts { handler: 'AiEdgeGallery', data: <json string> }.
      final message = data as _ResultMessage;
      final handler = message.handler;
      if (handler != null && handler.toDart == resultChannel) {
        final payload = message.data;
        final text = (payload != null && payload.isA<JSString>())
            ? (payload as JSString).toDart
            : '';
        if (!completer.isCompleted) completer.complete(text);
      }
    }.toJS;

    web.window.addEventListener('message', onMessage);

    // For URL skills the parent cannot reach into a cross-origin/sandboxed frame
    // to inject, so eval the injection on load via contentWindow when reachable
    // (same-origin URL skills only); asset skills bake it into srcdoc above.
    if (source is UrlJsSource) {
      iframe.onload = (web.Event _) {
        try {
          iframe.contentWindow?.callMethod('eval'.toJS, injection.toJS);
        } catch (_) {
          // Cross-origin frame: the parent cannot inject. The skill page must
          // post back on its own; we simply time out if it never does.
        }
      }.toJS;
    }

    web.document.body?.appendChild(iframe);

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('JS skill did not respond', timeout),
      );
    } finally {
      web.window.removeEventListener('message', onMessage);
      iframe.remove();
    }
  }

  /// Reads the sibling `index.js` for an asset skill whose [html] references it.
  /// Returns an empty string when the JS is already inline (no reference), so
  /// [inlineSkillHtml] is a no-op. Mirrors the native arm's loader.
  Future<String> _loadSiblingJs(String htmlAssetKey, String html) async {
    if (!html.contains('index.js')) return '';
    final slash = htmlAssetKey.lastIndexOf('/');
    final jsKey = slash == -1
        ? 'index.js'
        : '${htmlAssetKey.substring(0, slash + 1)}index.js';
    try {
      return await rootBundle.loadString(jsKey);
    } catch (_) {
      // No sibling JS bundled (or a cross-origin <script src>): leave as-is.
      return '';
    }
  }

  /// Decodes the HTML body of a `data:text/html[;base64],<payload>` URL so it can
  /// be baked into `srcdoc` (percent-encoded and base64 forms both handled).
  static String _decodeDataUrlHtml(String url) {
    final comma = url.indexOf(',');
    if (comma == -1) return '';
    final meta = url.substring(0, comma);
    final payload = url.substring(comma + 1);
    if (meta.contains(';base64')) {
      return utf8.decode(base64Decode(payload));
    }
    return Uri.decodeComponent(payload);
  }
}

/// The shape OUR web wrapper posts back over `postMessage`:
/// `{ handler: 'AiEdgeGallery', data: '<json result string>' }`. Typed so the
/// `message` listener reads it without `dart:js_interop_unsafe`.
extension type _ResultMessage._(JSObject _) implements JSObject {
  external JSString? get handler;
  external JSAny? get data;
}
