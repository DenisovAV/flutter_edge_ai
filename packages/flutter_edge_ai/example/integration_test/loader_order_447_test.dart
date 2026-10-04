// #447, half one: the POISONED order, and why it cannot be repaired.
//
// Hypothesis (now measured, see loader_order_fixed_447_test.dart for the other
// half): whichever code path first opens libLiteRtLm decides, for the whole
// process, whether stream_proxy.c's ABI probe can see the library's exports.
//
//   * the LLM path opens it via stream_proxy_load_global -> RTLD_GLOBAL
//   * the embeddings/speech path opens it via DynamicLibrary.open, and Dart
//     passes only RTLD_LAZY, which is RTLD_LOCAL by POSIX default
//   * bionic's dlsym(RTLD_DEFAULT) walks only soinfos flagged RTLD_GLOBAL
//   * so an app that touches embeddings before generating leaves the probe
//     blind: litert_lm_stream_chunk_get_text resolves to NULL, that is read as
//     "pre-v0.15 library", the 4-arg callback is registered against a 2-arg
//     caller, and args 3 and 4 are whatever x2/x3 happen to hold
//
// MUST run on Android, and MUST run as its own process. On Apple dlopen is
// RTLD_GLOBAL by default and dlsym(RTLD_DEFAULT) searches every loaded image,
// so this file cannot fail there — which is exactly how #447 shipped: the
// dual-ABI work was verified on macOS, the one platform where the property is
// unfalsifiable.
//
//   flutter test integration_test/loader_order_447_test.dart -d <android>
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'loader_order_447_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'poisoned order: a plain DynamicLibrary.open hides the ABI symbols',
    () {
      expectLookupWorks();

      // Baseline. NOT "the symbol is not ambient" — that is true both when
      // nothing loaded the library and when something loaded it LOCALLY, and the
      // second is the very state under test. Asking whether it is mapped at all
      // separates them.
      expect(
        mappedInProcess('libLiteRtLm.so'),
        isFalse,
        reason:
            'libLiteRtLm was already mapped into this process before the test '
            'opened anything, so it cannot measure its own open',
      );

      // What the embeddings/speech path does: litert_bindings.dart's
      // _openLiteRt() -> DynamicLibrary.open('libLiteRtLm.so').
      final lib = DynamicLibrary.open('libLiteRtLm.so');

      // Sanity: the library really is loaded and really does export both
      // symbols. Handle-scoped lookup ignores RTLD_GLOBAL entirely, so this
      // succeeds even when the ambient lookup below fails. If THIS fails, the
      // bundled library predates v0.15 and the hypothesis is moot.
      expect(
        lib.providesSymbol(probeSymbol),
        isTrue,
        reason:
            'bundled libLiteRtLm does not export the v0.15 chunk accessors — '
            'different problem entirely',
      );
      expect(lib.providesSymbol(controlSymbol), isTrue);

      // THE ASSERTION. The symbols exist, are exported, and the probe still
      // cannot see them.
      expect(
        globallyVisible(probeSymbol),
        isFalse,
        reason:
            'dlsym(RTLD_DEFAULT) CAN see the accessors after an RTLD_LOCAL open. '
            'Then bionic promoted the flags, or Dart no longer opens with '
            'RTLD_LAZY alone — either way the #447 explanation is wrong and the '
            'fix rests on a false premise',
      );
      expect(globallyVisible(controlSymbol), isFalse);
    },
    skip: Platform.isAndroid ? null : 'Android only — unfalsifiable on Apple',
  );

  test(
    'the poisoning cannot be repaired by loading globally afterwards',
    () {
      expectLookupWorks();

      // Establishes its own precondition rather than inheriting one. dlopen is
      // idempotent, so this is a no-op when the test above already ran and is the
      // whole setup when this test runs alone. Inheriting it meant that running
      // this test in isolation failed with "bionic DID promote" — a false and
      // expensive diagnosis.
      DynamicLibrary.open('libLiteRtLm.so');
      expect(
        globallyVisible(controlSymbol),
        isFalse,
        reason: 'the library should be loaded but local at this point',
      );

      // This is what the LLM path already does today. It is why #447 is subtle:
      // the call SUCCEEDS. bionic returns the existing soinfo with its refcount
      // bumped and its original flags intact — re-dlopen does not promote.
      // glibc does promote, which is why Linux never showed this.
      final handle = loadGlobal('libLiteRtLm.so');
      expect(
        handle,
        isNot(nullptr),
        reason:
            'stream_proxy_load_global returned NULL — then the existing null '
            'check would already have caught this and #447 would have been a '
            'loud failure instead of a silent one',
      );

      expect(
        globallyVisible(probeSymbol),
        isFalse,
        reason:
            'a later RTLD_GLOBAL dlopen DID promote the soinfo. Then the fix '
            'could simply be "always call loadGlobal before probing" — much '
            'cheaper than making every load path global',
      );
    },
    skip: Platform.isAndroid ? null : 'Android only — unfalsifiable on Apple',
  );
}
