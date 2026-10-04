// The one registration fact that is this package's own: LiteRtLmEngine
// implements HuggingFaceResolverSource and hands core a LitertlmManifestResolver
// — the canonical `const` instance, which is what lets core's registerAll dedup
// an app's explicit `const LitertlmManifestResolver()` against it. Read through
// the seam `initialize()` itself uses, so no init path and no storage mock.
// What core does with the handover (explicit list first, equal-priority tie,
// dedup) is core's contract, tested in
// flutter_edge_ai/test/core/registry/resolver_registration_test.dart.

import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAi;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmEngine;
import 'package:flutter_edge_ai_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LiteRtLmEngine contributes LitertlmManifestResolver', () {
    final derived = FlutterEdgeAi.engineHuggingFaceResolvers(const [
      LiteRtLmEngine(),
    ]);
    expect(derived, hasLength(1));
    expect(derived.single, isA<LitertlmManifestResolver>());
  });

  test('the carried resolver is the canonical const instance (dedup seam)', () {
    final derived = FlutterEdgeAi.engineHuggingFaceResolvers(const [
      LiteRtLmEngine(),
    ]);
    expect(derived.single, same(const LitertlmManifestResolver()));
  });
}
