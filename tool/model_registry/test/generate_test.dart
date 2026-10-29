// What the generator writes for a variant the registry withholds: it stays
// in the catalog (a published getter is never removed), deprecated, and its
// withheld backends reach every kind of variant.

import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/generate.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final registry = Directory(p.normalize(p.join('..', '..', 'model_registry')));
  final entries = checkRegistry(registry).entries;

  Entry edited(String id, void Function(Map<String, Object?> variant) edit) {
    final entry = entries.firstWhere((e) => e.id == id);
    final copy = _deepCopy(entry.data);
    edit((copy['variants']! as List).first as Map<String, Object?>);
    return Entry(entry.file, copy);
  }

  String litert(List<Entry> list) => generateAll(
    registry,
    list,
  ).firstWhere((f) => f.path.endsWith('litert_catalog.g.dart')).content;

  String speech(List<Entry> list) => generateAll(
    registry,
    list,
  ).firstWhere((f) => f.path.endsWith('speech_catalog.g.dart')).content;

  test('a withheld LLM variant stays, deprecated, withheld from all', () {
    final out = litert(entries);
    final getter = RegExp(
      r'@Deprecated\(\s*'
      r"'Withheld: [^']*'\s*\)\s*LiteRtLmVariant get standard",
    );
    expect(out, matches(getter));
    expect(
      out,
      contains(
        'withheld: {PreferredBackend.cpu, PreferredBackend.gpu, '
        'PreferredBackend.npu},',
      ),
    );
    expect(out, contains(r'_qwen3_0_6b$standard,'));
  });

  test('text backends are the file\'s; a withheld one is only withheld:', () {
    final out = litert(entries);
    final int4 = out.substring(
      out.indexOf(r'const _translategemma4bIt$int4 ='),
    );
    final block = int4.substring(0, int4.indexOf(');\n'));
    expect(block, contains('PreferredBackend.gpu, PreferredBackend.cpu}'));
    expect(block, contains('withheld: {PreferredBackend.gpu},'));
  });

  test('withhold_backends reaches an embedder and a speech variant', () {
    const reason = {'reason': 'Broken.', 'issue': 'https://x/1'};
    final list = [
      for (final e in entries)
        if (e.id == 'embeddinggemma-300m')
          edited(e.id, (v) => v['withhold_backends'] = {'cpu': reason})
        else if (e.id == 'moonshine-tiny')
          edited(e.id, (v) => v['withhold_backends'] = {'gpu': reason})
        else
          e,
    ];
    expect(
      RegExp(r'withheld: \{PreferredBackend\.cpu\},').allMatches(litert(list)),
      hasLength(1),
    );
    expect(
      RegExp(r'withheld: \{PreferredBackend\.gpu\},').allMatches(speech(list)),
      hasLength(1),
    );
  });

  test('a deprecated variant names what to use', () {
    final list = [
      for (final e in entries)
        if (e.id == 'moonshine-tiny')
          edited(e.id, (v) => v['deprecated'] = {'reason': 'Old.', 'use': 'x'})
        else
          e,
    ];
    expect(speech(list), contains("@Deprecated('Old. Use x.')"));
    final multiLine = [
      for (final e in entries)
        if (e.id == 'moonshine-tiny')
          edited(e.id, (v) => v['deprecated'] = {'reason': 'Line one.\nTwo.'})
        else
          e,
    ];
    expect(speech(multiLine), contains(r"@Deprecated('Line one.\nTwo.')"));
  });
}

Map<String, Object?> _deepCopy(Map<String, Object?> m) => {
  for (final MapEntry(:key, :value) in m.entries)
    key: switch (value) {
      Map<String, Object?> v => _deepCopy(v),
      List v => [
        for (final x in v) x is Map<String, Object?> ? _deepCopy(x) : x,
      ],
      _ => value,
    },
};
