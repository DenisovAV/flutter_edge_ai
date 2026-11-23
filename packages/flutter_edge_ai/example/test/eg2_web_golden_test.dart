// The web suites' frozen LiteRT-LM 0.18 goldens (decision M: the page runs
// @litert-lm/core 0.18.0 through 2.6.0) measure the same inputs as the native
// goldens, which moved to 0.19 on 2026-11-04: the same strings and prefixes,
// the same clips (by sha256), the same combined inputs. Only the vectors and
// the builds that wrote them differ, and those must still be 0.18's.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/goldens/eg2_audio_golden.dart';
import '../integration_test/goldens/eg2_audio_golden_web.dart';
import '../integration_test/goldens/eg2_text_golden.dart';
import '../integration_test/goldens/eg2_text_golden_web.dart';

Map<String, dynamic> _json(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

/// [group]'s entries without their vectors and the numbers measured on them.
Map<String, dynamic> _inputs(Map<String, dynamic> golden, String group) => {
  for (final MapEntry(:key, :value)
      in (golden[group] as Map<String, dynamic>).entries)
    key: {
      for (final MapEntry(key: field, :value)
          in (value as Map<String, dynamic>).entries)
        if (!field.startsWith('vector') && !field.startsWith('cos_'))
          field: value,
    },
};

void main() {
  test('text: the same items, prefixes and Sentence Transformers vectors; '
      'the 0.18.0-d build', () {
    final web = _json(eg2TextGoldenWebJson);
    final native = _json(eg2TextGoldenJson);
    expect(web['prefixes'], native['prefixes']);
    expect(web['model'], native['model']);
    List<Map<String, dynamic>> items(Map<String, dynamic> golden) => [
      for (final item in golden['items'] as List)
        {
          for (final MapEntry(:key, :value)
              in (item as Map<String, dynamic>).entries)
            if (key != 'vector_f32le') key: value,
        },
    ];
    expect(items(web), items(native));
    expect((web['native_library'] as Map)['tag'], 'native-v0.18.0-d');
  });

  test('audio: the same clips, variants and combined inputs; the 0.18.0 '
      'wheel and the 0.18.0-e build', () {
    final web = _json(eg2AudioGoldenWebJson);
    final native = _json(eg2AudioGoldenJson);
    expect(web['bundle'], native['bundle']);
    expect(web['prefixes'], native['prefixes']);
    expect(web['part_order'], native['part_order']);
    for (final group in ['clips', 'variants', 'combined']) {
      expect(_inputs(web, group), _inputs(native, group), reason: group);
    }
    expect((web['runtime'] as Map)['litert-lm'], '0.18.0');
    expect(
      (web['native_library'] as Map)['build'],
      startsWith('native-v0.18.0-e'),
    );
  });
}
