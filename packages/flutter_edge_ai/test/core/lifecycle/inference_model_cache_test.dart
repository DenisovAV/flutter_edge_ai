import 'dart:async';

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/lifecycle/inference_model_cache.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/core/registry/runtime_config.dart'
    show ActiveModelParams;
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

InferenceModelSpec _spec(String name) => InferenceModelSpec(
  name: name,
  modelSource: ModelSource.network('https://x/$name.litertlm'),
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
);

InferenceModelIdentity _identity(String name) {
  final spec = _spec(name);
  return (spec: spec, modelType: spec.modelType, fileType: spec.fileType);
}

void main() {
  late List<String> built;

  InferenceModelRequest request(
    String name, {
    int maxTokens = 1024,
    Future<InferenceModel> Function()? build,
  }) => (
    identity: _identity(name),
    params: ActiveModelParams(maxTokens: maxTokens),
    label: name,
    build:
        build ??
        () async {
          built.add('$name/$maxTokens');
          return _Model();
        },
  );

  setUp(() => built = []);

  test('a late close listener of a superseded model leaves the new one '
      'cached', () async {
    final cache = InferenceModelCache();
    final first = await cache.obtain(() => request('a')) as _Model;
    // Other knobs: the cache closes the first model and builds a second. The
    // first's listener has not fired yet — an engine may fire it late.
    final second = await cache.obtain(() => request('a', maxTokens: 2048));
    expect(cache.model, same(second));

    first.fireLate();
    expect(cache.model, same(second));
  });

  test('a failed build leaves nothing cached, and the next call builds '
      'again', () async {
    final cache = InferenceModelCache();
    await expectLater(
      cache.obtain(
        () => request('a', build: () async => throw StateError('no engine')),
      ),
      throwsStateError,
    );
    expect(cache.model, isNull);

    await cache.obtain(() => request('a'));
    expect(built, ['a/1024']);
  });

  test('a caller that waited for a build in flight resolves its request '
      'again, so a model installed meanwhile is the one built', () async {
    final cache = InferenceModelCache();
    final gate = Completer<void>();
    final firstBuild = cache.obtain(
      () => request(
        'a',
        build: () async {
          await gate.future;
          built.add('a/1024');
          return _Model();
        },
      ),
    );
    await pumpEventQueue();

    // A second caller with other knobs waits for the first build. While it
    // waits, another model becomes active.
    var active = 'a';
    final second = cache.obtain(() => request(active, maxTokens: 2048));
    await pumpEventQueue();
    active = 'b';

    gate.complete();
    await firstBuild;
    await second;
    expect(built, ['a/1024', 'b/2048']);
  });
}

class _Model implements InferenceModel {
  final _listeners = <void Function()>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  void addCloseListener(void Function() listener) => _listeners.add(listener);

  /// Closes without firing the listeners, as an engine whose listener fires
  /// late would.
  @override
  Future<void> close() async => _closed = true;

  void fireLate() {
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
