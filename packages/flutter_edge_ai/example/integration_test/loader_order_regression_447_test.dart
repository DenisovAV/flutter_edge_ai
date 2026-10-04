// #447 anti-regression: the embeddings/speech loader must not poison the
// process for the LLM path.
//
// Its two companions establish the linker mechanism in the abstract. This one
// exercises the REAL entry point: `LiteRtBindings.open()`, which is what the
// embedding forward pass and every flutter_edge_ai_speech core call reach for.
// Before the fix it called a plain `DynamicLibrary.open`, and an app that
// embedded or transcribed anything before generating left stream_proxy.c's ABI
// probe permanently blind.
//
// This file is the one that FAILS if the fix is reverted. Run it first in a
// clean process — the property under test is about being first.
//
//   flutter test integration_test/loader_order_regression_447_test.dart -d <android>
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/litert_bindings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'loader_order_447_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the embeddings loader leaves the ABI symbols reachable',
    () {
      expectLookupWorks();

      // Nothing may have opened the library yet, or "it stayed visible" would be
      // someone else's doing.
      expect(
        mappedInProcess('libLiteRtLm.so'),
        isFalse,
        reason:
            'libLiteRtLm was already mapped before this test ran; run this file '
            'on its own, it can only measure a clean process',
      );

      // The embeddings/speech path, arriving FIRST — the order that broke #447.
      // No model is loaded: opening the bindings is enough to reach _openLiteRt.
      final bindings = LiteRtBindings.open();
      expect(bindings, isNotNull);

      // THE ASSERTION. With the plain open this is false, and every later
      // generation registers the wrong stream-callback ABI.
      expect(
        globallyVisible(probeSymbol),
        isTrue,
        reason:
            'the embeddings loader left libLiteRtLm outside the default search '
            'scope, so stream_proxy.c cannot see the v0.15 chunk accessors and '
            'will register the 4-arg callback against a 2-arg caller — #447',
      );
      expect(globallyVisible(controlSymbol), isTrue);

      // And the LLM path, arriving second, still gets a working handle.
      final llmView = DynamicLibrary.open('libLiteRtLm.so');
      expect(llmView.providesSymbol(probeSymbol), isTrue);
      expect(globallyVisible(probeSymbol), isTrue);
    },
    skip: Platform.isAndroid ? null : 'Android only — unfalsifiable on Apple',
  );
}
