/// Web smoke tests for the LiteRT-LM `.litertlm` web inference path
/// (added in flutter_gemma 0.16.2, via `@litert-lm/core`).
///
/// Run with: `flutter test test/web/litert_lm_web_test.dart --platform chrome`
///
/// After the flutter_gemma 0.16.2 part-of refactor, `LiteRtLmWebInferenceModel` lives inside
/// the `flutter_edge_ai_web.dart` library (alongside `WebInferenceModel` and
/// `WebModelSourceResolver`). End-to-end behaviour (Engine.create, streaming,
/// OPFS) is exercised manually by `example/integration_test/litertlm_web_test.dart`
/// via `flutter drive -d chrome`.
///
/// This file is now a sanity check that the web library compiles in a Chrome
/// test environment — the surface itself is verified end-to-end at integration
/// time.
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/web/flutter_edge_ai_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flutter_edge_ai_web library compiles in Chrome test runner', () {
    // The mere fact that the import above resolves under --platform chrome
    // proves the part-of unification (LiteRtLmWebInferenceModel,
    // WebModelSourceResolver, WebInferenceModel) is well-formed.
    expect(FlutterEdgeAiWeb.new, isNotNull);
  });
}
