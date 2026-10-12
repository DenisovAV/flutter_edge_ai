@TestOn('browser')
library;

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
// ignore: implementation_imports — constructs an OPFS source to prove rejection without opening a stream.
import 'package:flutter_edge_ai/src/infrastructure/web_opfs_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/infrastructure/web_opfs_service.dart';
import 'package:flutter_edge_ai_llama/src/model_location_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

final _spec = InferenceModelSpec(
  name: 'weights',
  modelSource: AssetSource('weights'),
  modelType: ModelType.gemma4,
  fileType: ModelFileType.gguf,
);
const _config = RuntimeConfig(modelPath: '', maxTokens: 512);

void main() {
  test('public Web resolver uses the installed URL', () async {
    final resolver = _Resolver(
      _spec,
      const BlobUrlModelSource('blob:installed'),
    );
    expect(
      await resolveModelLocation(_spec, _config, resolver: resolver),
      'blob:installed',
    );
    expect(resolver.specReads, 0);
    expect(resolver.sourceReads, 1);
  });

  test('OPFS stream fails with an actionable typed error', () async {
    final resolver = _Resolver(
      _spec,
      OpfsStreamModelSource(_UnusedOpfs(), 'weights'),
    );
    await expectLater(
      resolveModelLocation(_spec, _config, resolver: resolver),
      throwsA(
        isA<llama.LlamaUnsupportedException>().having(
          (e) => e.toString(),
          'diagnostic',
          contains('WebStorageMode.cacheApi'),
        ),
      ),
    );
  });

  test('explicit resolved URL avoids an active-model lookup', () async {
    final resolver = _Resolver(_spec, const BlobUrlModelSource('blob:stale'));
    const config = RuntimeConfig(modelPath: 'blob:explicit', maxTokens: 512);
    expect(
      await resolveModelLocation(_spec, config, resolver: resolver),
      'blob:explicit',
    );
    expect(resolver.specReads + resolver.sourceReads, 0);
    await expectLater(
      resolveModelLocation(
        _spec,
        const RuntimeConfig(modelPath: 'opfs://weights', maxTokens: 512),
      ),
      throwsA(isA<llama.LlamaUnsupportedException>()),
    );
  });

  test(
    'missing active identity propagates without reaching model loading',
    () async {
      final resolver = _Resolver(_spec, const BlobUrlModelSource('blob:unused'))
        ..error = NoActiveModelError('Install a GGUF model first.');
      await expectLater(
        resolveModelLocation(_spec, _config, resolver: resolver),
        throwsA(same(resolver.error)),
      );
    },
  );
}

class _Resolver implements WebModelSourceResolver {
  _Resolver(this.spec, this.source);
  final InferenceModelSpec spec;
  final WebModelSource source;
  int specReads = 0;
  int sourceReads = 0;
  Object? error;
  @override
  Future<InferenceModelSpec> activeInferenceSpec() async {
    specReads++;
    if (error != null) throw error!;
    return spec;
  }

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async {
    sourceReads++;
    if (error != null) throw error!;
    return (model: source, loraPath: null);
  }
}

class _UnusedOpfs implements WebOPFSService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('OPFS stream must never be opened');
}
