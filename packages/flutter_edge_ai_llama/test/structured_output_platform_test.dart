@TestOn('vm')
library;

import 'dart:ffi';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/src/structured_output_platform_native.dart';
import 'package:flutter_edge_ai_llama/src/structured_output_web_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats are enabled only on the hosts and backends that ran', () {
    expect(
      structuredOutputHostRefusal(
        edge.PreferredBackend.cpu,
        abi: Abi.macosArm64,
      ),
      isNull,
    );
    expect(
      structuredOutputHostRefusal(
        edge.PreferredBackend.gpu,
        abi: Abi.macosArm64,
      ),
      isNull,
    );
    for (final abi in [
      Abi.macosX64,
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.windowsX64,
      Abi.windowsArm64,
      Abi.androidArm64,
      Abi.androidX64,
      Abi.iosArm64,
    ]) {
      for (final backend in [
        edge.PreferredBackend.cpu,
        edge.PreferredBackend.gpu,
      ]) {
        expect(
          structuredOutputHostRefusal(backend, abi: abi),
          allOf(contains('$abi'), contains(backend.name)),
          reason: '$abi ${backend.name}',
        );
      }
    }
  });

  test('a model whose device is unknown enforces no format', () {
    expect(
      structuredOutputHostRefusal(null, abi: Abi.macosArm64),
      contains('did not report which device'),
    );
  });

  const chrome =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  test(
    'the Web enables Chrome on macOS, dart2wasm and WebGPU together only',
    () {
      expect(
        webStructuredOutputRefusal(
          edge.PreferredBackend.gpu,
          userAgent: chrome,
          wasm: true,
        ),
        isNull,
      );
      for (final (backend, userAgent, wasm, missing) in [
        (edge.PreferredBackend.gpu, chrome, false, 'dart2js'),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
          true,
          'only macOS has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
          true,
          'only macOS has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/156.0.0.0 Mobile Safari/537.36',
          true,
          'only macOS has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (X11; CrOS x86_64 16000.0.0) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
          true,
          'only macOS has run',
        ),
        (
          edge.PreferredBackend.gpu,
          // Chrome on iPadOS asks for desktop sites: a Mac user agent with
          // CriOS, WebKit underneath.
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/156.0.0.0 '
              'Safari/604.1',
          true,
          'only macOS has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/156.0.0.0 '
              'Mobile/15E148 Safari/604.1',
          true,
          'only macOS has run',
        ),
        (edge.PreferredBackend.cpu, chrome, true, 'WebAssembly CPU runtime'),
        (null, chrome, true, 'did not report'),
        (
          edge.PreferredBackend.gpu,
          '$chrome Edg/156.0.0.0',
          true,
          'only Chrome has run',
        ),
        (
          edge.PreferredBackend.gpu,
          '$chrome OPR/120.0.0.0',
          true,
          'only Chrome has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 15.6; rv:140.0) '
              'Gecko/20100101 Firefox/140.0',
          true,
          'only Chrome has run',
        ),
        (
          edge.PreferredBackend.gpu,
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
              '(KHTML, like Gecko) Version/26.0 Safari/605.1.15',
          true,
          'only Chrome has run',
        ),
      ]) {
        expect(
          webStructuredOutputRefusal(backend, userAgent: userAgent, wasm: wasm),
          contains(missing),
          reason: '$backend $userAgent $wasm',
        );
      }
    },
  );
}
