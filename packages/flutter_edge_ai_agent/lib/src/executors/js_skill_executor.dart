import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../skill.dart';
import '../skill_executor.dart';
import '../skill_result.dart';
import 'js_runtime.dart';

/// Runs a [SkillType.js] skill by loading its `scripts/index.html` into a
/// **headless, sandboxed** webview and invoking the skill's global
/// `window.ai_edge_gallery_get_result(data, secret)` — the exact contract from
/// google-ai-edge/gallery, so their JS skills run unmodified.
///
/// The flow mirrors Gallery's [AgentChatScreen] injection:
/// 1. Load the skill HTML ([JsSkillSource.asset] for bundled starter skills, or
///    [JsSkillSource.url] for community skills).
/// 2. Register a single result bridge ([_resultChannel]) — the ONLY native
///    callback exposed to the foreign page.
/// 3. Inject a script that waits for `ai_edge_gallery_get_result` to appear,
///    calls it with the JSON-encoded `data` and `secret`, and posts the
///    returned JSON string back over the bridge.
/// 4. [parseJsResult] turns that JSON string into a [SkillResult].
///
/// SECURITY: the webview is configured as a sandbox — JavaScript can only talk
/// back through the single result bridge (no file access, no arbitrary native
/// bridge), and the [secret] is passed as a JS argument, NEVER via the model
/// prompt. Cross-origin/file navigations away from the loaded page are blocked.
class JsSkillExecutor extends SkillExecutor {
  JsSkillExecutor({
    required this.sourceFor,
    this.timeout = const Duration(seconds: 30),
    @visibleForTesting JsRuntime? runtime,
  }) : _runtime = runtime ?? createJsRuntime();

  /// Resolves a [Skill] to the location of its runnable HTML. Bundled starter
  /// skills return a [JsSkillSource.asset]; community skills a
  /// [JsSkillSource.url].
  final JsSkillSource Function(Skill skill) sourceFor;

  /// How long to wait for the skill's JS to call back before giving up.
  final Duration timeout;

  final JsRuntime _runtime;

  @override
  String get name => 'JsSkillExecutor';

  @override
  bool canExecuteSkill(Skill skill) => skill.type == SkillType.js;

  @override
  Future<SkillResult> execute(
    Skill skill,
    String dataJson, {
    String? secret,
  }) async {
    if (!isAvailable) {
      return const ErrorResult(
        'JsSkillExecutor: webview is not available on this platform.',
      );
    }
    final source = sourceFor(skill);
    try {
      final raw = await _runtime.run(
        source: source,
        dataJson: dataJson,
        secret: secret ?? '',
        timeout: timeout,
      );
      return parseJsResult(raw);
    } catch (e) {
      return ErrorResult('JsSkillExecutor: $e');
    }
  }

  /// Whether a headless webview can run here. `flutter_inappwebview` supports
  /// Android, iOS, macOS and Windows; the web arm runs a `package:web` iframe.
  /// Linux has no implementation, so JS skills are unavailable there and
  /// [execute] returns an [ErrorResult] instead of throwing.
  ///
  /// Uses [defaultTargetPlatform] (works on web, where `dart:io`'s `Platform`
  /// does not compile) so this file pulls neither `dart:io` nor the plugin.
  bool get isAvailable {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }
}

/// Where a JS skill's runnable HTML lives.
sealed class JsSkillSource {
  const JsSkillSource();

  /// A Flutter asset bundled with the app (the starter skills ship this way),
  /// e.g. `assets/skills/calculate-hash/scripts/index.html`.
  const factory JsSkillSource.asset(String assetKey) = AssetJsSource;

  /// A remote URL (community skills loaded by URL, Gallery-compatible).
  const factory JsSkillSource.url(String url) = UrlJsSource;
}

class AssetJsSource extends JsSkillSource {
  const AssetJsSource(this.assetKey);

  /// Flutter asset key of the skill's `index.html`. The native runtime reads it
  /// (plus any sibling `index.js`) via [rootBundle] and loads it as inline HTML.
  final String assetKey;
}

class UrlJsSource extends JsSkillSource {
  const UrlJsSource(this.url);

  final String url;
}

/// The single result-bridge name the injected script posts results to.
/// Kept Gallery-compatible. Shared by both runtime arms (native callHandler /
/// web postMessage) so the bridge name has one source of truth.
const String resultChannel = 'AiEdgeGallery';

/// Builds the async IIFE injected into the loaded page. It waits (up to ~10 s)
/// for the skill's global to be defined, calls it with the JSON-encoded [data]
/// and [secret], and posts the returned JSON string back to the host.
///
/// The skill contract — `window.ai_edge_gallery_get_result(data, secret)` — is
/// IDENTICAL across arms (Gallery-compatible); only OUR result-post wrapper is
/// engine-parameterized via [web]:
///   * native ([web] false) posts through `flutter_inappwebview.callHandler`;
///   * web ([web] true) posts through `window.parent.postMessage` (the
///     inappwebview web arm has no JS bridge, so the web runtime uses an iframe).
///
/// [data] and [secret] are JSON-encoded here so the values are passed as JS
/// arguments — never interpolated as code, never put in the model prompt.
///
/// Internal: shared by both runtime arms (`js_runtime_io.dart` /
/// `js_runtime_web.dart`) and exercised directly by the host unit tests.
String buildInjectionScript(
  String dataJson,
  String secret, {
  required bool web,
}) {
  // JSON-encode to safely embed both values as JS string/value literals.
  // `dataJson` is already a JSON document; wrap it as a JSON string so the JS
  // side receives the same string Gallery passes (the skill parses it itself).
  final safeData = jsonEncode(dataJson);
  final safeSecret = jsonEncode(secret);
  // The one line that differs by arm: how OUR wrapper posts the result back.
  // Web targetOrigin is '*' (not location.origin): the skill runs in a
  // sandbox="allow-scripts" iframe whose origin is opaque ("null"), so
  // postMessage(msg, location.origin) would target "null" and the browser would
  // drop the message before it reaches the real parent origin. The parent's
  // message listener gates on the '$resultChannel' handler tag, not the origin,
  // so '*' is safe here.
  final post = web
      ? "window.parent.postMessage({ handler: '$resultChannel', data: __x }, '*');"
      : "window.flutter_inappwebview.callHandler('$resultChannel', __x);";
  final script =
      '''
(async function() {
  function __post(__x) { $post }
  try {
    var startTs = Date.now();
    while (true) {
      if (typeof ai_edge_gallery_get_result === 'function') break;
      await new Promise(function(r) { setTimeout(r, 100); });
      if (Date.now() - startTs > 10000) {
        __post(JSON.stringify({ error: 'ai_edge_gallery_get_result is not defined' }));
        return;
      }
    }
    var result = await ai_edge_gallery_get_result($safeData, $safeSecret);
    __post(typeof result === 'string' ? result : JSON.stringify(result));
  } catch (e) {
    __post(JSON.stringify({ error: String((e && e.message) || e) }));
  }
})();
''';
  // Both runtime arms wrap this output in an inline `<script>…</script>` (the
  // loopback-served entry HTML on native, the iframe `srcdoc` on web). The
  // jsonEncoded `safeData`/`safeSecret` literals can contain a literal
  // `</script>` (jsonEncode does not escape `/`), which would terminate that
  // inline tag early and let the rest parse as markup — a model-supplied `data`
  // value could then break out into the secure-context page that holds the
  // secret. Escape it here, at the single source, exactly like inlineSkillHtml
  // does for the skill's own JS.
  return _escapeForInlineScript(script);
}

/// Escapes any `</script` (case-insensitive) so the string is safe to embed in
/// an inline `<script>…</script>` element without the HTML parser terminating
/// the tag early. Mirrors the guard in [inlineSkillHtml].
String _escapeForInlineScript(String js) =>
    js.replaceAll(RegExp('</script', caseSensitive: false), r'<\/script');

/// Splices [js] into [html] as an inline `<script>…</script>`, replacing the
/// skill's `<script src="index.js"></script>` reference. Inline asset loading is
/// required because iOS/macOS `loadFile` hardcodes `allowingReadAccessTo: nil`,
/// so a sibling `<script src="index.js">` would never load — the skill would
/// silently time out. Skills whose JS is already inline (no `index.js` tag) are
/// returned unchanged.
///
/// PURE function (no webview) so the asset-inlining is host-testable.
///
/// Internal: shared by both runtime arms (`js_runtime_io.dart` /
/// `js_runtime_web.dart`) and exercised directly by the host unit tests.
String inlineSkillHtml(String html, String js) {
  // Match <script src="index.js"></script> tolerating single/double quotes and
  // whitespace; the skills ship the canonical form but be forgiving.
  final tag = RegExp(
    r'''<script\s+src\s*=\s*['"]index\.js['"]\s*>\s*</script>''',
    caseSensitive: false,
  );
  if (!tag.hasMatch(html)) return html;
  // Guard against an accidental </script> inside the JS closing our tag early.
  final safeJs = js.replaceAll('</script>', r'<\/script>');
  return html.replaceFirst(tag, '<script>$safeJs</script>');
}

/// Parses the JSON string a JS skill returns from
/// `ai_edge_gallery_get_result` into a [SkillResult].
///
/// Recognised shapes (Gallery-compatible — any one key, others null/absent):
///   * `{ "result": "text" }`                       → [TextResult]
///   * `{ "image": { "base64": "data:image/png;base64,..." } }` → [ImageResult]
///   * `{ "webview": { "url": "...", "iframe": true } }`        → [WebviewResult]
///   * `{ "error": "message" }`                      → [ErrorResult]
///
/// Precedence matches Gallery's `runJs`: a non-null `error` wins; otherwise
/// image/webview are surfaced and `result` text carried alongside (here we
/// return the richest single variant). If [raw] is not valid JSON, or is valid
/// JSON with none of the known keys, the whole string is treated as a plain
/// [TextResult] (Gallery's "treat its whole as a result string" fallback).
///
/// This is a PURE function (no webview) so the result protocol is host-testable.
SkillResult parseJsResult(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    // Not JSON at all → the skill returned a bare string.
    return TextResult(raw);
  }

  if (decoded is! Map) {
    // Valid JSON but not an object (e.g. a bare JSON string/number) → text.
    return TextResult(raw);
  }
  final map = decoded;

  final error = _asNonEmptyString(map['error']);
  final result = _asNonEmptyString(map['result']);
  final image = map['image'];
  final webview = map['webview'];

  // No known keys at all → treat the whole payload as a result string.
  if (error == null && result == null && image == null && webview == null) {
    return TextResult(raw);
  }

  // Error takes precedence.
  if (error != null) {
    return ErrorResult(error);
  }

  // Image: { base64: "data:<mime>;base64,...." } (full Data URI per Gallery).
  // A declared-but-undecodable image must NOT fall through to the text branch —
  // that would silently drop the image and report success with only the caption.
  if (image is Map) {
    final bytes = _decodeImage(_asNonEmptyString(image['base64']));
    if (bytes != null) return ImageResult(bytes);
    return const ErrorResult(
      'JsSkillExecutor: skill returned an "image" whose base64 was missing or '
      'not decodable.',
    );
  }

  // Webview: { url, iframe }.
  if (webview is Map) {
    final url = _asNonEmptyString(webview['url']);
    if (url != null) {
      // Only http/https may be embedded. A model-supplied `javascript:` or
      // `data:text/html,…` URL would otherwise execute in the in-tree webview.
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
        return ErrorResult(
          'JsSkillExecutor: refusing to open a non-http(s) webview URL.',
        );
      }
      final iframe = webview['iframe'];
      return WebviewResult(url, iframe: iframe is bool ? iframe : true);
    }
  }

  // Plain text result.
  if (result != null) return TextResult(result);

  // Known key present but malformed (e.g. image with no decodable base64).
  return const ErrorResult('JsSkillExecutor: malformed skill result');
}

String? _asNonEmptyString(Object? v) {
  if (v is String && v.isNotEmpty) return v;
  return null;
}

/// Decodes a base64 image payload. Accepts either a raw base64 string or a full
/// Data URI (`data:image/png;base64,<...>`), matching Gallery's `image.base64`.
Uint8List? _decodeImage(String? value) {
  if (value == null) return null;
  var b64 = value;
  final comma = b64.indexOf(',');
  if (b64.startsWith('data:') && comma != -1) {
    b64 = b64.substring(comma + 1);
  }
  try {
    return base64Decode(b64);
  } catch (_) {
    return null;
  }
}

/// The headless-webview side of [JsSkillExecutor], abstracted so the executor
/// (and its [parseJsResult] contract) can be unit-tested on a host with no
/// display by injecting a fake [JsRuntime].
abstract class JsRuntime {
  /// Loads [source], injects the skill call, and returns the raw JSON string
  /// the skill posted back. Throws on timeout.
  Future<String> run({
    required JsSkillSource source,
    required String dataJson,
    required String secret,
    required Duration timeout,
  });
}
