@TestOn('vm')
library;

import 'package:flutter_edge_ai_agent/src/ui/webview_widget_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iframeShellHtml (native WebviewResult embedding)', () {
    test(
      'wraps the URL in an <iframe> so embed-only pages get nested context',
      () {
        const url = 'https://maps.google.com/maps?q=Paris&output=embed';
        final html = iframeShellHtml(url);

        // The URL must be embedded as a nested <iframe src=...>, NOT loaded as the
        // top document (which breaks Google Maps' "must be used in an iframe").
        // `&` is HTML-attribute-escaped to `&amp;` inside the src attribute.
        expect(html, contains('<iframe src="'));
        expect(html, contains('maps.google.com/maps?q=Paris&amp;output=embed'));
        expect(html, contains('</iframe>'));
      },
    );

    test('escapes the URL so it cannot break out of the src attribute', () {
      final html = iframeShellHtml(
        'https://x.test/a"><script>alert(1)</script>',
      );

      // No raw attribute-terminating quote survives inside src, and no raw
      // <script> is injected into the shell.
      expect(html, isNot(contains('src="https://x.test/a">')));
      expect(html, isNot(contains('<script>alert(1)</script>')));
    });
  });
}
