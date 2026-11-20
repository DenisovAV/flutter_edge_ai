// The hand-written bindings declare every function of any_shim.h with the
// same parameter count and the same C types, and nothing else.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C type in the header -> the Dart native type the bindings use.
const _cToDart = {
  'any_shim_status': 'Status',
  'uint32_t': 'Uint32',
  'void': 'Void',
  'void*': 'Pointer<Void>',
  'char*': 'Pointer<Utf8>',
  'char**': 'OutStr',
  'uint64_t': 'Uint64',
  'uintptr_t': 'UintPtr',
  'uint64_t*': 'Pointer<Uint64>',
  'int64_t': 'Int64',
  'int64_t*': 'Pointer<Int64>',
  'int32_t': 'Int32',
  'int32_t*': 'Pointer<Int32>',
  'float*': 'Pointer<Float>',
};

String _norm(String t) =>
    t.replaceAll(RegExp(r'\s+'), ' ').replaceAll(' *', ' *').trim();

Map<String, List<String>> _header() {
  final src = File(
    'native/any_shim/include/any_shim.h',
  ).readAsStringSync().replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = <String, List<String>>{};
  for (final m in RegExp(
    r'^(any_shim_status|uint32_t|void) (any_shim_\w+)\(([^)]*)\);',
    multiLine: true,
  ).allMatches(src)) {
    final params = m.group(3)!.trim();
    final types = <String>[_cToDart[m.group(1)!]!];
    if (params != 'void') {
      for (final p in params.split(',')) {
        final decl = _norm(p);
        final type = decl
            .substring(0, decl.lastIndexOf(RegExp(r'[ *]')) + 1)
            .trim();
        final dart = _cToDart[type.replaceAll(' ', '')];
        if (dart == null) {
          fail('no mapping for C type "$type" in ${m.group(2)}');
        }
        types.add(dart);
      }
    }
    out[m.group(2)!] = types;
  }
  return out;
}

Map<String, List<String>> _bindings() {
  final src = File('lib/src/ffi/any_shim_bindings.dart').readAsStringSync();
  final out = <String, List<String>>{};
  for (final m in RegExp(
    r'@Native<\s*(\w+) Function\(([^)]*?)\)\s*>\([^)]*\)\s*external \w+ (any_shim_\w+)\(',
    dotAll: true,
  ).allMatches(src)) {
    final params = m
        .group(2)!
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    out[m.group(3)!] = [m.group(1)!, ...params];
  }
  return out;
}

void main() {
  test('every header function is bound with the same signature', () {
    final h = _header();
    final d = _bindings();
    expect(h, hasLength(51));
    expect(d.keys.toSet(), h.keys.toSet());
    for (final name in h.keys) {
      expect(d[name], h[name], reason: name);
    }
  });

  test('the ABI constant matches the header', () {
    final header = File(
      'native/any_shim/include/any_shim.h',
    ).readAsStringSync();
    final bindings = File(
      'lib/src/ffi/any_shim_bindings.dart',
    ).readAsStringSync();
    final h = RegExp(
      r'#define ANY_SHIM_ABI_VERSION (\d+)',
    ).firstMatch(header)!.group(1);
    final d = RegExp(
      r'const int anyShimAbiVersion = (\d+);',
    ).firstMatch(bindings)!.group(1);
    expect(d, h);
  });
}
