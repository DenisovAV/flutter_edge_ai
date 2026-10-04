import 'package:flutter_edge_ai/core/api/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_source.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show InferenceModel;
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake resolver — probe-chain selection is what these tests exercise,
/// so [resolve] is never called.
class _R implements HuggingFaceResolver {
  _R(this._n, this._pri, {this.accepts = true});
  final String _n;
  final int _pri;
  final bool accepts;
  @override
  String get name => _n;
  @override
  int get priority => _pri;
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) => accepts;
  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async => throw UnimplementedError();
}

/// Engine that opts into [HuggingFaceResolverSource] and returns [_resolver].
class _EngineWithResolver
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  _EngineWithResolver(this._resolver);
  final HuggingFaceResolver _resolver;
  @override
  String get name => 'with-resolver';
  @override
  int get priority => 0;
  @override
  bool canHandle(InferenceModelSpec spec) => false;
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
  @override
  HuggingFaceResolver get huggingFaceResolver => _resolver;
}

/// Plain engine — no [HuggingFaceResolverSource]. Contributes nothing.
class _PlainEngine implements InferenceEngineProvider {
  @override
  String get name => 'plain';
  @override
  int get priority => 0;
  @override
  bool canHandle(InferenceModelSpec spec) => false;
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

void main() {
  setUp(() => HuggingFaceResolverRegistry.instance.reset());

  group('HuggingFaceResolverRegistry (mirrors EngineRegistry probe-chain)', () {
    test('picks highest priority', () {
      HuggingFaceResolverRegistry.instance.registerAll([
        _R('low', 0),
        _R('high', 10),
      ]);
      expect(HuggingFaceResolverRegistry.instance.findFor('o/r')!.name, 'high');
    });

    test('first-registered breaks ties on equal priority', () {
      HuggingFaceResolverRegistry.instance.registerAll([
        _R('first', 5),
        _R('second', 5),
      ]);
      expect(
        HuggingFaceResolverRegistry.instance.findFor('o/r')!.name,
        'first',
      );
    });

    test('findFor null when empty; hasAny false', () {
      expect(HuggingFaceResolverRegistry.instance.findFor('o/r'), isNull);
      expect(HuggingFaceResolverRegistry.instance.hasAny, isFalse);
    });

    test('skips resolvers that decline the repo', () {
      HuggingFaceResolverRegistry.instance.registerAll([
        _R('declines', 10, accepts: false),
        _R('accepts', 0),
      ]);
      expect(
        HuggingFaceResolverRegistry.instance.findFor('o/r')!.name,
        'accepts',
      );
    });

    test('dedupes identical registrations', () {
      final r = _R('a', 0);
      HuggingFaceResolverRegistry.instance.registerAll([r, r]);
      expect(HuggingFaceResolverRegistry.instance.registered.length, 1);
    });
  });

  test(
    'ResolvedHfModel keeps identity + overridable runtime defaults apart',
    () {
      const r = ResolvedHfModel(
        file: 'model.litertlm',
        url: 'https://huggingface.co/o/r/resolve/main/model.litertlm',
        fileType: ModelFileType.litertlm,
        modelType: ModelType.qwen3,
        sha256: 'abc',
        sizeBytes: 123,
        runtime: ModelRuntimeDefaults(
          maxTokens: 4096,
          isThinking: true,
          minOutputTokens: 2048,
        ),
      );
      expect(r.file, 'model.litertlm');
      expect(r.fileType, ModelFileType.litertlm);
      expect(r.modelType, ModelType.qwen3);
      expect(r.runtime.maxTokens, 4096);
      expect(r.runtime.isThinking, true);
      expect(r.runtime.minOutputTokens, 2048);
      // A field the manifest was silent on stays null → falls back to the SDK
      // default at the call site.
      expect(r.runtime.preferredBackend, isNull);
      expect(r.runtime.supportImage, isNull);
      // Default identity/runtime is all-null (no manifest hints).
      const bare = ResolvedHfModel(
        file: 'm',
        url: 'u',
        fileType: ModelFileType.litertlm,
      );
      expect(bare.modelType, isNull);
      expect(bare.runtime.maxTokens, isNull);
      expect(bare.notes, isEmpty);
    },
  );

  group('getActiveModel defaults merge (mergeRuntimeDefault)', () {
    test('explicit argument wins over manifest default and SDK default', () {
      expect(FlutterEdgeAi.mergeRuntimeDefault(512, 2048, 1024), 512);
      expect(FlutterEdgeAi.mergeRuntimeDefault(true, false, false), isTrue);
    });

    test('manifest default wins when the explicit argument is omitted', () {
      expect(FlutterEdgeAi.mergeRuntimeDefault(null, 2048, 1024), 2048);
      expect(FlutterEdgeAi.mergeRuntimeDefault<bool>(null, true, false), isTrue);
    });

    test(
      'SDK default applies when both are null (unchanged legacy behaviour)',
      () {
        expect(FlutterEdgeAi.mergeRuntimeDefault<int>(null, null, 1024), 1024);
        expect(
          FlutterEdgeAi.mergeRuntimeDefault<bool>(null, null, false),
          isFalse,
        );
      },
    );
  });

  test(
    'resolveHuggingFace throws a clear StateError when nothing registered',
    () {
      HuggingFaceResolverRegistry.instance.reset();
      expect(
        FlutterEdgeAi.resolveHuggingFace('org/repo'),
        throwsA(isA<StateError>()),
      );
    },
  );

  group('engineHuggingFaceResolvers (auto-derivation from engines)', () {
    test('collects a resolver only from engines that provide one', () {
      final r = _R('litertlm', 0);
      final derived = FlutterEdgeAi.engineHuggingFaceResolvers([
        _EngineWithResolver(r),
        _PlainEngine(), // no HuggingFaceResolverSource → skipped
      ]);
      expect(derived, hasLength(1));
      expect(derived.single, same(r));
    });

    test('empty when no engine implements HuggingFaceResolverSource', () {
      expect(
        FlutterEdgeAi.engineHuggingFaceResolvers([_PlainEngine()]),
        isEmpty,
      );
    });

    test('explicit resolver wins the tie over an engine-derived one '
        '(initialize registers the explicit list first)', () {
      final explicit = _R('explicit', 0);
      final engine = _EngineWithResolver(_R('engine', 0));
      // Mirror initialize(): explicit list FIRST, engine-derived SECOND, so the
      // explicit resolver wins on equal priority (findFor: first-registered).
      HuggingFaceResolverRegistry.instance.registerAll([explicit]);
      HuggingFaceResolverRegistry.instance.registerAll(
        FlutterEdgeAi.engineHuggingFaceResolvers([engine]),
      );
      expect(
        HuggingFaceResolverRegistry.instance.findFor('o/r')!.name,
        'explicit',
      );
    });
  });
}
