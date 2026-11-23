// The `@litert-lm/core` version lives in one place,
// `liteRtLmWebRuntimeVersion`: the web arm is written and measured against
// it, and its messages quote it. The pages and the setup snippets this
// repository ships must import exactly that version, or an app copies a
// loader for a runtime the package was never run on.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

/// Files that carry the module script or its version, relative to this
/// package. The codelabs and the website run the published packages and move
/// with a release.
const _carriers = [
  'README.md',
  '../flutter_edge_ai_litertlm/README.md',
  '../flutter_edge_ai/example/web/index.html',
  '../genkit_flutter_edge_ai/example/web/index.html',
];

void main() {
  test('the module URL is the pinned version on jsDelivr', () {
    expect(
      liteRtLmWebModuleUrl,
      'https://cdn.jsdelivr.net/npm/@litert-lm/core@'
      '$liteRtLmWebRuntimeVersion/+esm',
    );
  });

  for (final path in _carriers) {
    test('$path imports @litert-lm/core $liteRtLmWebRuntimeVersion', () {
      final text = File(path).readAsStringSync();
      final pins = RegExp(
        r'@litert-lm/core@([0-9][^/]*)/',
      ).allMatches(text).map((m) => m.group(1)).toList();
      expect(pins, isNotEmpty, reason: '$path has no module script any more');
      expect(pins, everyElement(liteRtLmWebRuntimeVersion));
    });
  }
}
