import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    LiteRtWebRuntime.wasmPath =
        'https://cdn.jsdelivr.net/npm/@litertjs/core@'
        '${LiteRtWebRuntime.pinnedVersion}/wasm/';
  });

  // The pin is not cosmetic: web/litert.js is the JS half of the runtime and
  // calls the WASM entry points of the release it was built against (0.2.x
  // called loadAndCompileWebGpu; 2.x has loadModel + compileModel). Mixing
  // halves fails at the first embedding, in a browser, with an error that
  // names neither version.
  //
  // The oracle is the lockfile npm wrote, not a literal typed here: a version
  // asserted against a copy of itself cannot catch "rebuilt the bundle, forgot
  // the constant", which is the only way this drifts.
  test('the pin matches the @litertjs/core the bundle was built from', () {
    final lock = File('tool/web_build/package-lock.json');
    if (!lock.existsSync()) {
      // The lockfile ships with the package, so this only fires when the test
      // runs from somewhere without the repo layout.
      markTestSkipped('no lockfile — running outside the repo');
      return;
    }
    final packages =
        (jsonDecode(lock.readAsStringSync()) as Map)['packages'] as Map;
    final resolved =
        (packages['node_modules/@litertjs/core'] as Map)['version'] as String;

    expect(
      LiteRtWebRuntime.pinnedVersion,
      resolved,
      reason:
          'web/litert.js was built from @litertjs/core $resolved, so the WASM '
          'runtime must come from that release too. Update pinnedVersion.',
    );
  });

  test('the default points at the pinned release', () {
    expect(
      LiteRtWebRuntime.wasmPath,
      'https://cdn.jsdelivr.net/npm/@litertjs/core@'
      '${LiteRtWebRuntime.pinnedVersion}/wasm/',
    );
  });

  test('an app can point it at its own copy', () {
    LiteRtWebRuntime.wasmPath = '/wasm/';
    expect(LiteRtWebRuntime.wasmPath, '/wasm/');
  });
}
