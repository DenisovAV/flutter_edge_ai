// #447, half two: the CORRECT order.
//
// Its companion (loader_order_447_test.dart) shows that a plain
// DynamicLibrary.open first leaves the ABI probe blind, and that loading
// globally afterwards does not repair it. That rules out every "repair"
// strategy and leaves only prevention — so the fix must guarantee the FIRST
// open is the global one.
//
// This file asks whether that guarantee is sufficient: once the library is in
// the process with RTLD_GLOBAL, does a later plain open take it back out of
// the default search scope? If it does, ordering alone cannot fix #447 and
// every load path has to be converted. If it does not, the fix is a Dart-side
// ordering change with no native rebuild.
//
// MUST run on Android, and MUST run as its OWN process — a clean one. Merging
// it into the companion file would silently invalidate one of the two.
//
//   flutter test integration_test/loader_order_fixed_447_test.dart -d <android>
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'loader_order_447_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an RTLD_GLOBAL preload survives a later plain DynamicLibrary.open',
    () {
      expectLookupWorks();

      expect(
        mappedInProcess('libLiteRtLm.so'),
        isFalse,
        reason:
            'libLiteRtLm was already mapped into this process; "global first" is '
            'then not what is being measured',
      );

      // The LLM path, arriving first.
      final handle = loadGlobal('libLiteRtLm.so');
      expect(handle, isNot(nullptr), reason: 'RTLD_GLOBAL preload failed');

      // Precondition, not the point of the test: if the preload does not make
      // the symbols ambient, everything below is measuring nothing.
      expect(
        globallyVisible(probeSymbol),
        isTrue,
        reason:
            'the RTLD_GLOBAL preload did not put the exports in the default '
            'search scope at all — then stream_proxy could never have worked on '
            'Android, which contradicts every passing litertlm test we have',
      );

      // The embeddings/speech path, arriving second. This is the exact call
      // that poisons a clean process; here it lands on an already-global
      // soinfo.
      final lib = DynamicLibrary.open('libLiteRtLm.so');
      expect(lib.providesSymbol(probeSymbol), isTrue);

      // THE ASSERTION.
      expect(
        globallyVisible(probeSymbol),
        isTrue,
        reason:
            'a later RTLD_LOCAL open DEMOTED an already-global soinfo. Then '
            'ordering alone cannot fix #447: every load path in every package '
            'would have to go through stream_proxy_load_global, and a Dart-side '
            'ordering change would leave the bug reachable',
      );
      expect(globallyVisible(controlSymbol), isTrue);
    },
    skip: Platform.isAndroid ? null : 'Android only — unfalsifiable on Apple',
  );
}
