import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 transparent PNG, base64-encoded (used to assert image decoding).
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQAY3Y2wAAAAAElFTkSuQmCC';

void main() {
  group('parseJsResult', () {
    test('result → TextResult', () {
      final r = parseJsResult(jsonEncode({'result': 'hello world'}));
      expect(r, isA<TextResult>());
      expect((r as TextResult).text, 'hello world');
    });

    test('image (raw base64) → ImageResult', () {
      final r = parseJsResult(
        jsonEncode({
          'image': {'base64': _pngB64},
        }),
      );
      expect(r, isA<ImageResult>());
      final bytes = (r as ImageResult).bytes;
      expect(bytes, isA<Uint8List>());
      expect(bytes, equals(base64Decode(_pngB64)));
    });

    test('image (full data URI) → ImageResult strips the prefix', () {
      final r = parseJsResult(
        jsonEncode({
          'image': {'base64': 'data:image/png;base64,$_pngB64'},
        }),
      );
      expect(r, isA<ImageResult>());
      expect((r as ImageResult).bytes, equals(base64Decode(_pngB64)));
    });

    test('webview → WebviewResult with url + iframe', () {
      final r = parseJsResult(
        jsonEncode({
          'webview': {'url': 'https://example.com/map', 'iframe': true},
        }),
      );
      expect(r, isA<WebviewResult>());
      final w = r as WebviewResult;
      expect(w.url, 'https://example.com/map');
      expect(w.iframe, isTrue);
    });

    test('webview refuses non-http(s) URLs (javascript:/data:)', () {
      // A model-supplied javascript: or data: URL must NOT become a live
      // WebviewResult that executes in the in-tree webview.
      for (final url in [
        'javascript:alert(1)',
        'data:text/html,<script>alert(1)</script>',
        'file:///etc/passwd',
      ]) {
        final r = parseJsResult(
          jsonEncode({
            'webview': {'url': url, 'iframe': true},
          }),
        );
        expect(r, isA<ErrorResult>(), reason: url);
      }
    });

    test('webview defaults iframe to true when absent', () {
      final r = parseJsResult(
        jsonEncode({
          'webview': {'url': 'https://example.com'},
        }),
      );
      expect((r as WebviewResult).iframe, isTrue);
    });

    test('webview respects iframe:false', () {
      final r = parseJsResult(
        jsonEncode({
          'webview': {'url': 'https://example.com', 'iframe': false},
        }),
      );
      expect((r as WebviewResult).iframe, isFalse);
    });

    test('error → ErrorResult', () {
      final r = parseJsResult(jsonEncode({'error': 'boom'}));
      expect(r, isA<ErrorResult>());
      expect((r as ErrorResult).message, 'boom');
    });

    test('error wins over result/image (Gallery precedence)', () {
      final r = parseJsResult(
        jsonEncode({
          'error': 'denied',
          'result': 'ignored',
          'image': {'base64': _pngB64},
        }),
      );
      expect(r, isA<ErrorResult>());
      expect((r as ErrorResult).message, 'denied');
    });

    test('malformed (not JSON) → whole string as TextResult', () {
      final r = parseJsResult('not json at all');
      expect(r, isA<TextResult>());
      expect((r as TextResult).text, 'not json at all');
    });

    test('valid JSON with no known keys → whole payload as TextResult', () {
      final raw = jsonEncode({'foo': 'bar'});
      final r = parseJsResult(raw);
      expect(r, isA<TextResult>());
      expect((r as TextResult).text, raw);
    });

    test('bare JSON string → TextResult of the raw payload', () {
      final raw = jsonEncode('just a string');
      final r = parseJsResult(raw);
      expect(r, isA<TextResult>());
      expect((r as TextResult).text, raw);
    });

    test('known key present but malformed base64 → ErrorResult', () {
      final r = parseJsResult(
        jsonEncode({
          'image': {'base64': '!!!not-base64!!!'},
        }),
      );
      expect(r, isA<ErrorResult>());
    });

    test('empty strings are ignored (treated as absent)', () {
      // result:'' and error:'' both empty → no known content → whole as text.
      final raw = jsonEncode({'result': '', 'error': ''});
      final r = parseJsResult(raw);
      expect(r, isA<TextResult>());
      expect((r as TextResult).text, raw);
    });

    test(
      'declared-but-undecodable image with a caption → ErrorResult, not text',
      () {
        // Regression: a corrupt image alongside a result text must NOT silently
        // drop the image and return the caption as a success.
        final r = parseJsResult(
          jsonEncode({
            'result': 'here is your QR code',
            'image': {'base64': '!!!not-base64!!!'},
          }),
        );
        expect(r, isA<ErrorResult>());
      },
    );
  });

  group('buildInjectionScript', () {
    test('keeps the Gallery global name on both arms', () {
      expect(
        buildInjectionScript('{"q":"abc"}', 'sk-1', web: false),
        contains('ai_edge_gallery_get_result'),
      );
      expect(
        buildInjectionScript('{"q":"abc"}', 'sk-1', web: true),
        contains('ai_edge_gallery_get_result'),
      );
    });

    test('native arm posts via flutter_inappwebview callHandler', () {
      final script = buildInjectionScript('{"q":"abc"}', 'sk-1', web: false);
      expect(
        script,
        contains("window.flutter_inappwebview.callHandler('AiEdgeGallery'"),
      );
      // The native arm must NOT use the web postMessage bridge.
      expect(script, isNot(contains('postMessage')));
    });

    test('web arm posts via window.parent.postMessage', () {
      final script = buildInjectionScript('{"q":"abc"}', 'sk-1', web: true);
      expect(script, contains('window.parent.postMessage'));
      expect(script, contains("handler: 'AiEdgeGallery'"));
      // The web arm must NOT use the native callHandler bridge.
      expect(script, isNot(contains('callHandler')));
    });

    test('web arm targets origin "*" (skill runs in an opaque-origin frame)', () {
      // The skill iframe is sandbox="allow-scripts" (no allow-same-origin), so
      // its origin is opaque ("null"). postMessage(msg, location.origin) would
      // target "null" and the browser would drop the message before it reaches
      // the real parent origin. Must target '*' (the parent listener gates on
      // the handler tag, not the origin). Regression guard for that silent drop.
      final script = buildInjectionScript('{"q":"abc"}', 'sk-1', web: true);
      expect(script, contains("}, '*')"));
      expect(script, isNot(contains('location.origin')));
    });

    test('JSON-encodes data and secret as JS literals (no code injection)', () {
      // A secret containing a quote must not break out of the JS string.
      final script = buildInjectionScript(
        '{"q":"x"}',
        'a"; alert(1); "',
        web: false,
      );
      expect(script, contains(jsonEncode('a"; alert(1); "')));
      // data is wrapped as a JSON string literal.
      expect(script, contains(jsonEncode('{"q":"x"}')));
    });

    test(
      'escapes </script> in data/secret so it cannot break out of the tag',
      () {
        // Regression: jsonEncode does NOT escape '/', so a model-supplied data
        // value containing "</script>" would otherwise terminate the inline
        // <script> the runtime arms wrap this output in, breaking out into the
        // secure-context page that holds the secret.
        for (final web in [false, true]) {
          final script = buildInjectionScript(
            '{"x":"</script><img src=x onerror=alert(1)>"}',
            'sk-</script>-1',
            web: web,
          );
          expect(
            script,
            isNot(contains('</script>')),
            reason: 'no raw closing tag may survive (web: $web)',
          );
          expect(script, contains(r'<\/script'));
        }
      },
    );
  });

  group('inlineSkillHtml', () {
    test('splices index.js into the <script src> reference', () {
      const html =
          '<!DOCTYPE html><html><body><script src="index.js"></script></body></html>';
      const js = 'window.ai_edge_gallery_get_result = async () => "ok";';
      final out = inlineSkillHtml(html, js);
      expect(out, contains('<script>$js</script>'));
      expect(out, isNot(contains('src="index.js"')));
    });

    test('tolerates single quotes and extra whitespace in the src tag', () {
      const html = "<body><script  src = 'index.js' ></script></body>";
      const js = 'var x = 1;';
      final out = inlineSkillHtml(html, js);
      expect(out, contains('<script>var x = 1;</script>'));
      expect(out, isNot(contains('index.js')));
    });

    test('returns HTML unchanged when the JS is already inline', () {
      const html = '<body><script>var inline = true;</script></body>';
      final out = inlineSkillHtml(html, 'unused');
      expect(out, html);
    });

    test('escapes a stray </script> in the JS so it cannot close the tag', () {
      const html = '<body><script src="index.js"></script></body>';
      const js = 'var s = "</script>";';
      final out = inlineSkillHtml(html, js);
      // The literal </script> in the JS must be escaped, leaving exactly one
      // real closing tag (the one we add).
      expect(r'<\/script>'.allMatches(out).length, 1);
    });
  });

  group('JsSkillExecutor', () {
    Skill jsSkill() => const Skill(
      name: 'calculate-hash',
      description: 'hash things',
      instructions: 'Call run_js with index.html',
      type: SkillType.js,
    );

    test('canExecuteSkill only for SkillType.js', () {
      final exec = JsSkillExecutor(
        sourceFor: (_) => const JsSkillSource.asset('a/index.html'),
      );
      expect(exec.canExecuteSkill(jsSkill()), isTrue);
      expect(
        exec.canExecuteSkill(
          const Skill(
            name: 't',
            description: 'd',
            instructions: 'i',
            type: SkillType.textOnly,
          ),
        ),
        isFalse,
      );
    });

    test('canExecute (core String contract) bridges to the type', () {
      final exec = JsSkillExecutor(
        sourceFor: (_) => const JsSkillSource.asset('a/index.html'),
      );
      expect(exec.canExecute('js'), isTrue);
      expect(exec.canExecute('intent'), isFalse);
    });

    test('execute wires the runtime payload through parseJsResult', () async {
      final exec = JsSkillExecutor(
        sourceFor: (_) => const JsSkillSource.asset('a/index.html'),
        runtime: _FakeRuntime(jsonEncode({'result': 'ok'})),
      );
      final r = await exec.execute(jsSkill(), '{"x":1}', secret: 'sk');
      expect((r as TextResult).text, 'ok');
    });

    test('execute passes data + secret to the runtime', () async {
      final fake = _FakeRuntime(jsonEncode({'result': 'ok'}));
      final exec = JsSkillExecutor(
        sourceFor: (_) => const JsSkillSource.url('https://x/y.html'),
        runtime: fake,
      );
      await exec.execute(jsSkill(), '{"a":2}', secret: 'shh');
      expect(fake.lastData, '{"a":2}');
      expect(fake.lastSecret, 'shh');
      expect(fake.lastSource, isA<UrlJsSource>());
    });

    test('missing secret is passed as empty string, not null', () async {
      final fake = _FakeRuntime(jsonEncode({'result': 'ok'}));
      final exec = JsSkillExecutor(
        sourceFor: (_) => const JsSkillSource.asset('a/index.html'),
        runtime: fake,
      );
      await exec.execute(jsSkill(), '{}');
      expect(fake.lastSecret, '');
    });

    test(
      'runtime throwing yields an ErrorResult (no exception escapes)',
      () async {
        final exec = JsSkillExecutor(
          sourceFor: (_) => const JsSkillSource.asset('a/index.html'),
          runtime: _ThrowingRuntime(),
        );
        final r = await exec.execute(jsSkill(), '{}');
        expect(r, isA<ErrorResult>());
        expect((r as ErrorResult).message, contains('boom'));
      },
    );
  });
}

class _FakeRuntime implements JsRuntime {
  _FakeRuntime(this.reply);

  final String reply;
  JsSkillSource? lastSource;
  String? lastData;
  String? lastSecret;

  @override
  Future<String> run({
    required JsSkillSource source,
    required String dataJson,
    required String secret,
    required Duration timeout,
  }) async {
    lastSource = source;
    lastData = dataJson;
    lastSecret = secret;
    return reply;
  }
}

class _ThrowingRuntime implements JsRuntime {
  @override
  Future<String> run({
    required JsSkillSource source,
    required String dataJson,
    required String secret,
    required Duration timeout,
  }) async {
    throw StateError('boom');
  }
}
