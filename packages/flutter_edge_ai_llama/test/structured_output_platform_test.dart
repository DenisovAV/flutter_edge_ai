@TestOn('vm')
library;

import 'dart:ffi';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/src/structured_output_platform_native.dart';
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
}
