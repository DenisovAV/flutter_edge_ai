// The registration contract `FlutterEdgeAi.initialize()` makes to every engine
// package: an engine that implements HuggingFaceResolverSource has its resolver
// registered without a `huggingFaceResolvers:` entry; the explicit list is
// registered FIRST, so an app-supplied resolver wins the equal-priority tie and
// `resolveHuggingFace` reaches it; a `const` resolver passed both ways
// registers once. Driven through the full published `initialize()` path with a
// fake engine and fake resolvers, so it pins the contract rather than one
// engine. Each engine package checks only that its engine hands over its own
// resolver (flutter_edge_ai_litertlm: test/manifest/engine_carried_resolver_test.dart).
//
// Reproduction notes (each is the kind of thing the next person loses an
// hour to):
// - `initialize()` ends in the model manager's restore, which reads
//   shared_preferences. Under `flutter test` that plugin has no host, so the
//   call throws MissingPluginException — unless
//   `SharedPreferences.setMockInitialValues({})` runs first, which swaps in
//   the in-memory store and lets the whole init path complete headless.
// - `resolveHuggingFace` derives the platform key from
//   `defaultTargetPlatform`, so pin it (`debugDefaultTargetPlatformOverride`)
//   or the key the resolver sees depends on whichever host runs the suite.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_edge_ai/core/api/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_source.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show InferenceModel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = 'org/repo';

/// Const-constructible fake resolver. Accepts every repo at priority 0 — the
/// tie every engine-carried resolver sits at — and answers with a row that
/// names itself and echoes the platform key it was handed, so a test can tell
/// which resolver `resolveHuggingFace` reached without a mutable counter (which
/// the `const` instance in the dedup case could not carry).
class _FakeResolver implements HuggingFaceResolver {
  const _FakeResolver(this.name);
  @override
  final String name;
  @override
  int get priority => 0;
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) => true;
  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async => ResolvedHfModel(
    file: '$name.litertlm',
    url: 'fake://$name/$repo/$platform',
    fileType: ModelFileType.litertlm,
  );
}

/// Engine that opts into [HuggingFaceResolverSource] and contributes
/// [huggingFaceResolver] — the shape LiteRtLmEngine, OnnxEngine and
/// BuiltInAiEngine share.
class _FakeEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  const _FakeEngine(this.huggingFaceResolver);
  @override
  final HuggingFaceResolver huggingFaceResolver;
  @override
  String get name => 'fake-engine';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
    HuggingFaceResolverRegistry.instance.reset();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    HuggingFaceResolverRegistry.instance.reset();
    EngineRegistry.instance.reset();
    ServiceRegistry.reset();
  });

  test(
    'registering an engine auto-registers the resolver it carries',
    () async {
      const carried = _FakeResolver('engine');
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [_FakeEngine(carried)],
      );
      final registered = HuggingFaceResolverRegistry.instance.registered;
      expect(registered, hasLength(1));
      expect(registered.single, same(carried));
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          _repo,
          fileType: ModelFileType.litertlm,
        ),
        same(carried),
      );
    },
  );

  test('an explicit resolver wins the equal-priority tie over the '
      'engine-carried one, and resolveHuggingFace reaches it', () async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [_FakeEngine(_FakeResolver('engine'))],
      huggingFaceResolvers: const [_FakeResolver('explicit')],
    );
    expect(HuggingFaceResolverRegistry.instance.registered.map((r) => r.name), [
      'explicit',
      'engine',
    ], reason: 'explicit list first, engine-carried second');

    final r = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      fileType: ModelFileType.litertlm,
    );
    expect(r.file, 'explicit.litertlm');
    // The platform key comes from defaultTargetPlatform, pinned in setUp.
    expect(r.url, 'fake://explicit/$_repo/macos');
  });

  test('a const resolver passed both explicitly and via the engine registers '
      'once', () async {
    const shared = _FakeResolver('shared');
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [_FakeEngine(shared)],
      huggingFaceResolvers: const [shared],
    );
    final registered = HuggingFaceResolverRegistry.instance.registered;
    expect(registered, hasLength(1));
    expect(registered.single, same(shared));
  });
}
