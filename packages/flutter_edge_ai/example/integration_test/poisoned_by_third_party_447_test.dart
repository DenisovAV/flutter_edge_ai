// What happens when someone ELSE poisons the process — the case we cannot
// prevent, only diagnose.
//
// The other #447 tests all run in a process where our own load order wins. This
// one covers the residual case: app or third-party code opens libLiteRtLm
// locally before flutter_edge_ai runs at all (a plain `DynamicLibrary.open`, or a
// Java `System.loadLibrary`, which is RTLD_NOW *without* RTLD_GLOBAL). bionic
// never promotes, so the condition is permanent and our fix cannot repair it.
//
// The contract, then, is not "keep working" — it is:
//
//   * `.litertlm` generation FAILS LOUDLY instead of producing corrupt text
//   * embeddings and speech KEEP WORKING, because they resolve through their
//     own handle and never needed the symbols to be ambient
//
// Those two branches are the whole of the warn/require split, and nothing else
// in the suite reaches either of them: every other test runs in a process where
// the preload takes.
//
// The poisoning is done from the test body, which is a faithful stand-in — what
// matters is that it comes from outside the code under test, not that it comes
// from another app.
//
// MUST run as its own process: the poisoning is irreversible.
//
//   flutter test integration_test/poisoned_by_third_party_447_test.dart -d <android>
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/litert_bindings.dart';
// ignore: implementation_imports — the branches under test are internal by
// design; exporting them would invite apps to call an Android-only,
// RTLD-flag-sensitive primitive directly.
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_default_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'loader_order_447_support.dart';

const _lib = 'libLiteRtLm.so';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a process poisoned from outside fails loudly, but only where it must',
    () {
      expectLookupWorks();
      expect(
        mappedInProcess(_lib),
        isFalse,
        reason:
            'libLiteRtLm was already mapped, so this test cannot control the '
            'order it depends on',
      );

      // Stand in for the third party. This is the exact call that caused #447,
      // now made deliberately and from outside flutter_edge_ai.
      DynamicLibrary.open(_lib);
      expect(
        globallyVisible(controlSymbol),
        isFalse,
        reason:
            'the poisoning did not take, so neither branch below is reached',
      );

      // The `.litertlm` path must refuse. Silently continuing here is #447: the
      // ABI probe would read NULL, pick the 4-arg shape, and generation would
      // return text assembled from registers the caller never wrote.
      expect(
        () => openLiteRtLmRequiringDefaultScope(_lib),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('default search scope'), contains('447')),
          ),
        ),
        reason:
            'the inference path accepted a process where the stream-callback ABI '
            'cannot be determined',
      );

      // The embeddings/speech path must NOT refuse. It resolves through the
      // handle it is handed, so ambient visibility was never its concern, and
      // breaking it here would punish an app for a condition it does not depend
      // on. A warning is printed — deliberately with `print`, so it survives
      // release builds, unlike edgeAiLog and developer.log.
      final lib = openLiteRtLmPreferringDefaultScope(_lib);
      expect(
        lib.providesSymbol(controlSymbol),
        isTrue,
        reason:
            'the handle must still resolve symbols; that is the whole reason '
            'this path is allowed to continue',
      );

      // And the real entry point, end to end: a speech-only or embeddings-only
      // app still starts on a poisoned process.
      expect(
        LiteRtBindings.open,
        returnsNormally,
        reason:
            'a speech-only app was broken by a poisoning it does not depend on — '
            'exactly what the warn/require split exists to prevent',
      );
    },
    skip: Platform.isAndroid ? null : 'Android only — unfalsifiable on Apple',
  );
}
