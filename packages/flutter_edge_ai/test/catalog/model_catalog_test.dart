// The engine-free catalog types: an artifact's URL, the default variant
// choice, and the catalog of every registered package.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/catalog/registered_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixtures.dart';

void main() {
  group('ModelArtifact', () {
    test('the URL pins the revision and encodes each path segment', () {
      final a = artifact('dir with space/a+b.litertlm');
      expect(
        a.url,
        'https://huggingface.co/litert-community/tiny/resolve/$rev/'
        'dir%20with%20space/a%2Bb.litertlm',
      );
    });

    test('two artifacts are equal on repo, revision, path and sha256', () {
      expect(
        artifact('m.litertlm', installFilename: 'x'),
        artifact('m.litertlm', installFilename: 'y'),
      );
      expect(
        artifact('m.litertlm', sha: 'aa'),
        isNot(artifact('m.litertlm', sha: 'bb')),
      );
    });
  });

  group('CatalogModel.variantFor', () {
    const sm8750 = TestNpu(NpuVendor.qualcomm, 'SM8750');
    const sm8850 = TestNpu(NpuVendor.qualcomm, 'SM8850');
    final web = TestLlm('web', backendsHere: const {});
    final generic = TestLlm('generic');
    final cpuOnly = TestLlm('cpu', backendsHere: const {PreferredBackend.cpu});
    final npu8750 = TestLlm(
      'npu-sm8750',
      npuTarget: sm8750,
      backendsHere: const {PreferredBackend.npu},
    );
    final npu8850 = TestLlm(
      'npu-sm8850',
      npuTarget: sm8850,
      backendsHere: const {PreferredBackend.npu},
    );
    final model = TestModel('tiny-llm', [
      web,
      npu8750,
      generic,
      cpuOnly,
      npu8850,
    ]);

    test('picks the first variant that runs here and is not an NPU build', () {
      expect(model.variantFor(), same(generic));
    });

    test('a backend filters by what the variant runs on', () {
      expect(model.variantFor(backend: PreferredBackend.cpu), same(generic));
      expect(
        TestModel('m', [
          web,
          cpuOnly,
        ]).variantFor(backend: PreferredBackend.gpu),
        isNull,
      );
    });

    test('an NPU build is chosen for its SoC only', () {
      expect(model.variantFor(npu: sm8850), same(npu8850));
      expect(
        model.variantFor(
          backend: PreferredBackend.npu,
          npu: const TestNpu(NpuVendor.qualcomm, 'SM8650'),
        ),
        isNull,
      );
      expect(
        model.variantFor(npu: const TestNpu(NpuVendor.qualcomm, 'SM8650')),
        same(generic),
        reason: 'no build for that SoC: the generic one, off the NPU',
      );
    });

    test('asking for the NPU without a SoC throws, also for one SoC', () {
      expect(
        () => model.variantFor(backend: PreferredBackend.npu),
        throwsArgumentError,
      );
      expect(
        () => TestModel('m', [
          generic,
          npu8750,
        ]).variantFor(backend: PreferredBackend.npu),
        throwsArgumentError,
        reason: 'one SoC listed says nothing about the device\'s SoC',
      );
    });

    test('the SoC is compared without regard to case', () {
      expect(
        model.variantFor(npu: const TestNpu(NpuVendor.qualcomm, 'sm8850')),
        same(npu8850),
      );
      expect(
        model.variantFor(
          backend: PreferredBackend.npu,
          npu: const TestNpu(NpuVendor.qualcomm, 'Sm8750'),
        ),
        same(npu8750),
      );
    });

    test('nothing runs here: null', () {
      expect(TestModel('m', [web]).variantFor(), isNull);
    });
  });

  group('ModelCatalog lookups', () {
    final catalog = TestCatalog('c', [
      TestModel('tiny-llm', [TestLlm('generic')]),
    ]);

    test('by model id and by variant id', () {
      expect(catalog.byId('tiny-llm')?.id, 'tiny-llm');
      expect(catalog.byId('other'), isNull);
      expect(catalog.variantById('tiny-llm/generic')?.id, 'tiny-llm/generic');
      expect(catalog.variantById('tiny-llm/web'), isNull);
      expect(catalog.variantById('tiny-llm'), isNull);
    });
  });

  group('RegisteredCatalog', () {
    test(
      'one model id from two catalogs is one model, first catalog first',
      () {
        final a = TestLlm('a');
        final b = TestLlm('b');
        final first = TestCatalog('first', [
          TestModel('tiny-llm', [a], displayName: 'First'),
        ]);
        final second = TestCatalog('second', [
          TestModel('tiny-llm', [b], displayName: 'Second'),
          TestModel('other', [TestLlm('x', modelId: 'other')]),
        ]);
        final merged = RegisteredCatalog([
          TestSource(first),
          TestSource(second),
        ]);
        expect(merged.models.map((m) => m.id), ['tiny-llm', 'other']);
        final model = merged.byId('tiny-llm')!;
        expect(model.variants, [same(a), same(b)]);
        expect(model.displayName, 'First');
      },
    );

    test('one variant id from two catalogs throws, naming both', () {
      final first = TestCatalog('first', [
        TestModel('tiny-llm', [TestLlm('generic')]),
      ]);
      final second = TestCatalog('second', [
        TestModel('tiny-llm', [TestLlm('generic')]),
      ]);
      expect(
        () => RegisteredCatalog([TestSource(first), TestSource(second)]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('tiny-llm/generic'),
          ),
        ),
      );
    });

    test('a catalog reached through two providers counts once', () {
      final catalog = TestCatalog('c', [
        TestModel('tiny-llm', [TestLlm('a')]),
      ]);
      final merged = RegisteredCatalog([
        TestSource(catalog),
        TestSource(catalog),
      ]);
      expect(merged.models, hasLength(1));
      expect(merged.models.single.variants, hasLength(1));
      expect(
        merged.models.single,
        same(catalog.models.single),
        reason: 'not merged with itself',
      );
    });

    test('a provider without a catalog adds nothing', () {
      final merged = RegisteredCatalog([Object(), 'not a provider']);
      expect(merged.models, isEmpty);
    });

    test('a single-catalog model is the catalog\'s own object', () {
      final model = TestModel('tiny-llm', [TestLlm('a')]);
      final merged = RegisteredCatalog([
        TestSource(TestCatalog('c', [model])),
      ]);
      expect(merged.byId('tiny-llm'), same(model));
    });
  });
}
