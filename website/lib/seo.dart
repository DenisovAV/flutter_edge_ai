import 'dart:convert';

import 'package:jaspr/dom.dart' show RawText;
import 'package:jaspr/jaspr.dart';

/// Canonical production origin. SEO tags point here (NOT the *.web.app URL) so
/// indexing stays clean on the custom domain.
const String kSiteOrigin = 'https://flutteredge.ai';

/// Builds the `<head>` SEO components (Open Graph, Twitter Card, canonical,
/// robots, theme-color, and JSON-LD structured data) for a page.
/// Pass these to `Document(head: seoHead(...))`.
///
/// [path] is the page path beginning with '/', used for canonical + og:url.
/// [image] is an absolute-from-root path to the share image.
/// [structuredData] is optional JSON-LD; defaults to the site's
/// SoftwareApplication schema on the home page.
List<Component> seoHead({
  required String title,
  required String description,
  String path = '/',
  String image = '/images/og-image.png',
  String type = 'website',
  Map<String, Object?>? structuredData,
}) {
  final url = '$kSiteOrigin$path';
  final imageUrl = '$kSiteOrigin$image';

  Component meta(String key, String value, {bool property = false}) {
    return Component.element(
      tag: 'meta',
      attributes: {property ? 'property' : 'name': key, 'content': value},
    );
  }

  return [
    Component.element(
      tag: 'link',
      attributes: {'rel': 'canonical', 'href': url},
    ),
    meta('robots', 'index, follow'),
    meta('theme-color', '#0B2351'),
    // Open Graph
    meta('og:type', type, property: true),
    meta('og:site_name', 'Flutter Edge AI', property: true),
    meta('og:locale', 'en_US', property: true),
    meta('og:title', title, property: true),
    meta('og:description', description, property: true),
    meta('og:url', url, property: true),
    meta('og:image', imageUrl, property: true),
    meta('og:image:secure_url', imageUrl, property: true),
    meta('og:image:type', 'image/png', property: true),
    meta('og:image:width', '1200', property: true),
    meta('og:image:height', '630', property: true),
    meta('og:image:alt', 'Flutter Edge AI — On-device LLMs for Flutter', property: true),
    // Twitter Card
    meta('twitter:card', 'summary_large_image'),
    meta('twitter:title', title),
    meta('twitter:description', description),
    meta('twitter:image', imageUrl),
    // JSON-LD structured data
    Component.element(
      tag: 'script',
      attributes: {'type': 'application/ld+json'},
      children: [
        RawText(jsonEncode(structuredData ?? _softwareApplicationSchema())),
      ],
    ),
  ];
}

/// JSON-LD `SoftwareApplication` describing the flutter_edge_ai package, used for
/// rich results in search. Plain `Map`/`List` so it serializes deterministically.
Map<String, Object?> _softwareApplicationSchema() => {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  'name': 'Flutter Edge AI',
  'description':
      'A Flutter plugin to run Gemma and other LLMs on-device — '
      'Android, iOS, Web, and Desktop. Multimodal vision & audio, '
      'function calling, on-device agent skills, thinking mode, '
      'GPU acceleration, embeddings, and RAG.',
  'url': kSiteOrigin,
  'applicationCategory': 'DeveloperApplication',
  'operatingSystem': 'Android, iOS, Web, macOS, Windows, Linux',
  'offers': {
    '@type': 'Offer',
    'price': '0',
    'priceCurrency': 'USD',
  },
  'license': 'https://opensource.org/licenses/MIT',
  'author': {
    '@type': 'Person',
    'name': 'Sasha Denisov',
  },
  'codeRepository': 'https://github.com/DenisovAV/flutter_edge_ai',
  'sameAs': [
    'https://pub.dev/packages/flutter_edge_ai',
    'https://github.com/DenisovAV/flutter_edge_ai',
  ],
};
