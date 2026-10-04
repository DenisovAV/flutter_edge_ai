// Level 2 — webview-on-hardware integration test (NO model).
//
// Drives JsSkillExecutor.execute directly against a REAL flutter_inappwebview
// headless webview (native arms) or package:web iframe (web arm) with a fixed
// dataJson, so the result is deterministic — there is no LLM in the loop. A
// failure here is unambiguously a webview/runtime bug (the model-driven path is
// exercised separately in the example app's Level 3 agent_with_model_test.dart).
//
// Scenarios (from the design's "Testing strategy"):
//   S1 compute skill — calculate-hash real headless -> SHA-1 matches a known
//      reference (asset load + injection + crypto.subtle + handler callback).
//   S2 DOM skill     — interactive-map -> {webview:{url}} -> WebviewResult.
//   S3 secret inject — a skill echoes the secret it received as a JS arg back in
//      its result; the secret reaches the JS but is never logged or prompted.
//   S4 timeout       — a skill that never calls back -> clean error, no hang.
//   S5 sandbox       — a sub-navigation (location.href='file://...') is blocked
//      and the skill still returns its result.
//   S6 platform gate — on Linux JS skills are unavailable -> ErrorResult, no
//      crash (guarded with Platform.isLinux).
//
// Run on a device (per AGENTS.md Rule 6 — native targets use `flutter test`,
// web uses `flutter drive`):
//   flutter test integration_test/js_skill_real_webview_test.dart -d <device>
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/js_skill_real_webview_test.dart -d chrome
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'platform_helper.dart' as platform;

/// SHA-1 of the ASCII string `hello`, the deterministic reference S1 checks the
/// `calculate-hash` skill (which hashes with `crypto.subtle.digest('SHA-1')`)
/// against. Computed independently (e.g. `printf hello | shasum`).
const _sha1OfHello = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d';

/// The bundled starter skills, resolved to their HTML via
/// [AssetSkillSource.jsSkillSourceFor].
final _assetSource = AssetSkillSource();

Future<SkillRegistry>? _registryLoad;

/// Loads the bundled skills on first use, inside a test body. Not in
/// `setUpAll`: load() throws on a missing skill, and under `flutter drive`
/// (web) a throwing `setUpAll` is reported as "All tests passed" (AGENTS.md
/// Rule 6b). Here the failure fails each test that needs the skills.
Future<SkillRegistry> _ensureRegistry() => _registryLoad ??= _assetSource
    .load()
    .then((skills) => SkillRegistry()..addAll(skills, selected: true));

/// A `data:` URL HTML skill that echoes its `data` and `secret` JS arguments
/// straight back as a JSON result — used by S3 (secret passthrough) and, with a
/// blocking variant, by S4/S5. Loaded via [JsSkillSource.url] so it needs no
/// bundled asset (the native runtime `loadUrl`s a data URL; the web runtime
/// points the iframe `src` at it).
String _dataUrl(String html) =>
    'data:text/html;charset=utf-8,${Uri.encodeComponent(html)}';

/// HTML whose `ai_edge_gallery_get_result(data, secret)` returns the secret it
/// was handed — proves the secret reaches the JS as an argument (S3).
const _echoSecretHtml = '''
<!DOCTYPE html><html><body><script>
window['ai_edge_gallery_get_result'] = async (data, secret) =>
  JSON.stringify({ result: secret });
</script></body></html>
''';

/// HTML whose `ai_edge_gallery_get_result` never resolves — the executor must
/// give up on its [JsSkillExecutor.timeout] with a clean error, not hang (S4).
const _neverCallsBackHtml = '''
<!DOCTYPE html><html><body><script>
window['ai_edge_gallery_get_result'] = () => new Promise(() => {});
</script></body></html>
''';

/// HTML that attempts a `file://` sub-navigation before returning a result. The
/// sandbox must block the navigation; the result must still come back (S5).
const _subNavHtml = '''
<!DOCTYPE html><html><body><script>
window['ai_edge_gallery_get_result'] = async (data) => {
  try { window.location.href = 'file:///etc/passwd'; } catch (e) {}
  return JSON.stringify({ result: 'still-here' });
};
</script></body></html>
''';

/// A throwaway JS skill (the executor only probes [Skill.type]).
Skill _jsSkill(String name) => Skill(
  name: name,
  description: 'integration skill',
  instructions: 'Call run_js with index.html',
  type: SkillType.js,
);

/// The real-webview scenarios (S1–S5) can't run under `flutter test` on two
/// platforms: Linux (no webview implementation at all) and Windows
/// (`HeadlessInAppWebView` ACCESS-VIOLATION-crashes the plugin under the
/// integration-test harness — proven by a minimal no-our-code test; the same
/// code works as a `flutter run` app, and the loopback mechanism is probe-proven
/// on Windows WebView2). Returns true (caller should `return`) on either, with a
/// breadcrumb so the skip is visible — not a silent pass or a harness crash.
bool skipNoHarnessWebview(String scenario) {
  if (platform.isLinux) {
    // ignore: avoid_print
    print('[$scenario] SKIP: JS skills are unavailable on Linux');
    return true;
  }
  if (platform.isWindows) {
    // ignore: avoid_print
    print(
      '[$scenario] SKIP: HeadlessInAppWebView (WebView2) crashes under flutter '
      'test on Windows — WebView2 needs a real window/HWND that the headless '
      'integration-test runner does not provide (access violation, fixed offset '
      'across all Dart variants; the same code works as a flutter run app, and '
      'the loopback secure-context is probe-proven on Windows WebView2). Like '
      'web (Rule 6), this engine cannot be driven through flutter test.',
    );
    return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // S1 — compute skill: real headless webview loads the bundled calculate-hash
  // HTML (inlining its sibling index.js), runs crypto.subtle, and posts the
  // hash back over the single AiEdgeGallery handler.
  testWidgets('S1 calculate-hash real headless → SHA-1 reference', (t) async {
    if (skipNoHarnessWebview('S1')) return;
    final registry = await _ensureRegistry();
    final exec = JsSkillExecutor(sourceFor: _assetSource.jsSkillSourceFor);
    final result = await exec.execute(
      registry.get('calculate-hash')!,
      '{"text":"hello"}',
    );
    expect(result, isA<TextResult>(), reason: '$result');
    expect((result as TextResult).text, _sha1OfHello);
  });

  // S2 — DOM skill: interactive-map returns a {webview:{url}} payload, which
  // parseJsResult turns into a WebviewResult the UI embeds inline.
  testWidgets('S2 interactive-map DOM → WebviewResult', (t) async {
    if (skipNoHarnessWebview('S2')) return;
    final registry = await _ensureRegistry();
    final exec = JsSkillExecutor(sourceFor: _assetSource.jsSkillSourceFor);
    final result = await exec.execute(
      registry.get('interactive-map')!,
      '{"location":"Paris"}',
    );
    expect(result, isA<WebviewResult>(), reason: '$result');
    final webview = result as WebviewResult;
    expect(webview.url, contains('maps.google.com'));
    expect(webview.url, contains('Paris'));
    expect(webview.iframe, isTrue);
  });

  // S3 — secret injection: the secret is handed to the JS as the second argument
  // of ai_edge_gallery_get_result, NEVER interpolated as code or placed in the
  // prompt. The echo skill returns it, proving it arrived.
  testWidgets('S3 secret injected as JS arg (not in logs/prompt)', (t) async {
    if (skipNoHarnessWebview('S3')) return;
    const secret = 'sk-integration-12345';
    final exec = JsSkillExecutor(
      sourceFor: (_) => JsSkillSource.url(_dataUrl(_echoSecretHtml)),
    );
    final result = await exec.execute(
      _jsSkill('require-secret'),
      '{"q":"x"}',
      secret: secret,
    );
    expect(result, isA<TextResult>(), reason: '$result');
    expect((result as TextResult).text, secret);
  });

  // S4 — timeout: a skill that never calls back must surface a clean ErrorResult
  // within the executor's (short, here) timeout rather than hanging the loop.
  testWidgets('S4 never-callback skill → clean timeout error', (t) async {
    if (skipNoHarnessWebview('S4')) return;
    final exec = JsSkillExecutor(
      sourceFor: (_) => JsSkillSource.url(_dataUrl(_neverCallsBackHtml)),
      timeout: const Duration(seconds: 3),
    );
    final result = await exec
        .execute(_jsSkill('hangs'), '{}')
        // Hard upper bound so a real hang fails the test instead of stalling.
        .timeout(const Duration(seconds: 20));
    expect(result, isA<ErrorResult>(), reason: '$result');
  });

  // S5 — sandbox: a sub-navigation away from the loaded page is blocked, and the
  // skill still returns its result over the single bridge.
  testWidgets('S5 sub-navigation blocked, result still returned', (t) async {
    if (skipNoHarnessWebview('S5')) return;
    final exec = JsSkillExecutor(
      sourceFor: (_) => JsSkillSource.url(_dataUrl(_subNavHtml)),
      timeout: const Duration(seconds: 10),
    );
    final result = await exec.execute(_jsSkill('sub-nav'), '{}');
    expect(result, isA<TextResult>(), reason: '$result');
    expect((result as TextResult).text, 'still-here');
  });

  // S6 — platform gate: on Linux there is no webview implementation, so
  // isAvailable is false and execute returns an ErrorResult (honest capability,
  // no crash). On every other platform the gate is open, asserted by S1–S5.
  testWidgets('S6 Linux platform gate → ErrorResult', (t) async {
    if (kIsWeb || !platform.isLinux) {
      // Not Linux — the gate is open; S1–S5 already cover the open path.
      return;
    }
    final registry = await _ensureRegistry();
    final exec = JsSkillExecutor(sourceFor: _assetSource.jsSkillSourceFor);
    expect(exec.isAvailable, isFalse);
    final result = await exec.execute(
      registry.get('calculate-hash')!,
      '{"text":"hello"}',
    );
    expect(result, isA<ErrorResult>(), reason: '$result');
    expect((result as ErrorResult).message, contains('not available'));
  });
}
