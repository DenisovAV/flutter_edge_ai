// The rules for the page's `@litert-lm/core` `Backend` enum
// (`window.LiteRtLmBackend`), on the VM: both published layouts, and the
// refusals of a page that did not hand it over or handed something else.
//
// Run: dart test test/web/web_backend_ids_test.dart
library;

import 'package:litertlm_dart/internal.dart' show LiteRtLmWebBackend;
import 'package:litertlm_dart/src/web/web_backend_ids.dart';
import 'package:test/test.dart';

/// `Backend` in `wasm_binding_types.js` of 0.19.0 and 0.20.0, as the JS
/// reader hands it over (numbers as doubles, as dart2wasm reads them).
const _v019 = <String, Object?>{
  'UNSPECIFIED': 0.0,
  'CPU_ARTISAN': 1.0,
  'GPU_ARTISAN': 2.0,
  'CPU': 3.0,
  'GPU': 4.0,
  'GOOGLE_TENSOR_ARTISAN': 5.0,
  'NPU': 6.0,
};
const _v020 = <String, Object?>{
  'UNSPECIFIED': 0.0,
  'GPU_ARTISAN': 1.0,
  'CPU': 2.0,
  'GPU': 3.0,
  'GOOGLE_TENSOR_ARTISAN': 4.0,
  'NPU': 5.0,
};

Matcher _refused(String reason) => throwsA(
  isA<LiteRtLmWebBackendEnumError>()
      .having((e) => e, 'a StateError', isA<StateError>())
      .having(
        (e) => e.message,
        'message',
        allOf(contains(reason), contains(liteRtLmWebBackendShimLine)),
      ),
);

void main() {
  test('the shim line is the one the pages carry', () {
    expect(liteRtLmWebBackendShimLine, 'window.LiteRtLmBackend = m.Backend;');
  });

  for (final (version, layout, cpu, gpu, artisan) in [
    ('0.19.0', _v019, 3, 4, 2),
    ('0.20.0', _v020, 2, 3, 1),
  ]) {
    group(version, () {
      final ids = LiteRtLmWebBackendIds.parse(layout);

      test('the ids sent are the page\'s CPU and GPU', () {
        expect(ids.idOf(LiteRtLmWebBackend.cpu), cpu);
        expect(ids.idOf(LiteRtLmWebBackend.gpu), gpu);
        expect(ids.gpuArtisan, artisan);
      });

      test('ids read back: CPU is WebAssembly, GPU and GPU_ARTISAN WebGPU', () {
        expect(ids.backendOf(cpu), LiteRtLmWebBackend.cpu);
        expect(ids.backendOf(gpu), LiteRtLmWebBackend.gpu);
        expect(ids.backendOf(artisan), LiteRtLmWebBackend.gpu);
      });

      test('any other id is unknown, named by the page\'s enum', () {
        final npu = (layout['NPU']! as double).toInt();
        expect(ids.backendOf(npu), isNull);
        expect(ids.nameOf(npu), 'NPU in the page\'s Backend');
        expect(ids.backendOf(0), isNull);
        expect(ids.backendOf(42), isNull);
        expect(ids.nameOf(42), startsWith('not in the page\'s Backend (UNSP'));
      });
    });
  }

  test('the 0.19.0 CPU id is the 0.20.0 GPU: read from the page, never '
      'assumed', () {
    final old = LiteRtLmWebBackendIds.parse(_v019);
    final current = LiteRtLmWebBackendIds.parse(_v020);
    expect(current.backendOf(old.cpu), LiteRtLmWebBackend.gpu);
    expect(current.backendOf(old.gpu), isNull);
  });

  group('refused, naming the shim line', () {
    test('no window.LiteRtLmBackend', () {
      expect(
        () => LiteRtLmWebBackendIds.parse(null),
        _refused('window.LiteRtLmBackend is not set'),
      );
    });

    test('not an object', () {
      expect(
        () => LiteRtLmWebBackendIds.parse('a value of type function'),
        _refused('window.LiteRtLmBackend is a value of type function'),
      );
    });

    for (final name in ['CPU', 'GPU', 'GPU_ARTISAN']) {
      test('no $name', () {
        expect(
          () => LiteRtLmWebBackendIds.parse({..._v020}..remove(name)),
          _refused('it has no $name'),
        );
      });
    }

    test('an entry that is not an integer', () {
      expect(
        () => LiteRtLmWebBackendIds.parse({..._v020, 'GPU': 3.5}),
        _refused('its GPU is 3.5, not an integer'),
      );
      expect(
        () => LiteRtLmWebBackendIds.parse({..._v020, 'CPU': 'string'}),
        _refused('its CPU is a value of type string, not an integer'),
      );
      expect(
        () => LiteRtLmWebBackendIds.parse({..._v020, 'CPU': 'undefined'}),
        _refused('its CPU is undefined, not an integer'),
      );
    });

    test('two of CPU, GPU and GPU_ARTISAN equal', () {
      expect(
        () => LiteRtLmWebBackendIds.parse({..._v020, 'GPU_ARTISAN': 3.0}),
        _refused('are not three ids'),
      );
    });
  });
}
