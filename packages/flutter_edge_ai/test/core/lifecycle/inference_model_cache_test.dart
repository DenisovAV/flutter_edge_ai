import 'dart:async';

import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/lifecycle/inference_model_cache.dart';
import 'package:flutter_edge_ai/src/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart'
    show ActiveModelParams;
import 'package:flutter_edge_ai/src/interface.dart';
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

  test('two callers asking for the same model share one build', () async {
    final cache = InferenceModelCache();
    final first = cache.obtain(() => request('a'));
    final second = cache.obtain(() => request('a'));
    expect(await second, same(await first));
    expect(built, ['a/1024']);
  });

  test('a caller asking for other knobs waits for the build in flight, then '
      'replaces it', () async {
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
    final secondBuild = cache.obtain(() => request('a', maxTokens: 2048));
    await pumpEventQueue();
    expect(built, isEmpty);

    gate.complete();
    final first = await firstBuild;
    final second = await secondBuild;
    // The first caller gets the model it asked for, and the second closes it:
    // the cache holds one model.
    expect(built, ['a/1024', 'a/2048']);
    expect(first.isClosed, isTrue);
    expect(cache.model, same(second));
  });

  test('a failed build in flight fails its callers, and a caller with other '
      'knobs builds its own', () async {
    final cache = InferenceModelCache();
    final gate = Completer<void>();
    final failing = cache.obtain(
      () => request(
        'a',
        build: () async {
          await gate.future;
          throw StateError('no engine');
        },
      ),
    );
    final sharing = cache.obtain(() => request('a'));
    final other = cache.obtain(() => request('a', maxTokens: 2048));
    await pumpEventQueue();

    gate.complete();
    await expectLater(failing, throwsStateError);
    await expectLater(sharing, throwsStateError);
    expect(await other, same(cache.model));
    expect(built, ['a/2048']);
  });

  test('a model closed by its owner is built again once its close has '
      'finished', () async {
    final cache = InferenceModelCache();
    final teardown = Completer<void>();
    final first = await cache.obtain(
      () => request(
        'a',
        build: () async {
          built.add('a/1024');
          return _Model(onClose: () => teardown.future);
        },
      ),
    );
    // The app closes it without awaiting; its listener fires only at the end.
    unawaited(first.close());

    final next = cache.obtain(() => request('a'));
    await pumpEventQueue();
    expect(built, ['a/1024'], reason: 'no build while the model is closing');

    teardown.complete();
    expect(await next, isNot(same(first)));
    expect(built, ['a/1024', 'a/1024']);
  });

  test('a close that outlives its deadline fails the request with the name '
      'of the model still closing, and builds nothing', () async {
    final cache = InferenceModelCache(
      ModelCloseGate(const Duration(milliseconds: 50)),
    );
    final teardown = Completer<void>();
    await cache.obtain(
      () => request(
        'a',
        build: () async {
          built.add('a/1024');
          return _Model(onClose: () => teardown.future);
        },
      ),
    );

    await expectLater(
      cache.obtain(() => request('b')),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          contains('(a)'),
        ),
      ),
    );
    expect(built, ['a/1024']);
    expect(cache.model, isNull);
    teardown.complete();
  });

  test('a caller that waited for a close resolves its request again', () async {
    final cache = InferenceModelCache();
    final teardown = Completer<void>();
    await cache.obtain(
      () => request(
        'a',
        build: () async {
          built.add('a/1024');
          return _Model(onClose: () => teardown.future);
        },
      ),
    );

    // Another model is active: the cache closes 'a' first. While it waits for
    // that close, a third model becomes active.
    var active = 'b';
    final next = cache.obtain(() => request(active));
    await pumpEventQueue();
    active = 'c';

    teardown.complete();
    await next;
    expect(built, ['a/1024', 'c/1024']);
  });

  group('closeForRemoval', () {
    test('closes the cached model built from the file before the removal '
        'runs', () async {
      final cache = InferenceModelCache();
      final model = await cache.obtain(() => request('a')) as _Model;
      bool? closedAtRemoval;

      await cache.closeForRemoval('a.litertlm', () async {
        closedAtRemoval = model.isClosed;
      });

      expect(closedAtRemoval, isTrue);
      expect(model.closes, 1);
      expect(cache.model, isNull);
    });

    test('closes the model whose LoRA is the file', () async {
      final spec = InferenceModelSpec(
        name: 'a',
        modelSource: ModelSource.network('https://x/a.task'),
        loraSource: ModelSource.network('https://x/adapter.bin'),
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      );
      final cache = InferenceModelCache();
      final model =
          await cache.obtain(
                () => (
                  identity: (
                    spec: spec,
                    modelType: spec.modelType,
                    fileType: spec.fileType,
                  ),
                  params: ActiveModelParams(maxTokens: 1024),
                  build: () async => _Model(),
                ),
              )
              as _Model;

      await cache.closeForRemoval(spec.files.last.filename, () async {});

      expect(model.isClosed, isTrue);
      expect(cache.model, isNull);
    });

    test('leaves a model built from other files open and cached', () async {
      final cache = InferenceModelCache();
      final model = await cache.obtain(() => request('a')) as _Model;
      var removed = false;

      await cache.closeForRemoval('b.litertlm', () async => removed = true);

      expect(removed, isTrue);
      expect(model.isClosed, isFalse);
      expect(cache.model, same(model));
    });

    test('closes a build of the file in flight once it ends, before the '
        'removal runs', () async {
      final cache = InferenceModelCache();
      final gate = Completer<void>();
      _Model? made;
      final building = cache.obtain(
        () => request(
          'a',
          build: () async {
            await gate.future;
            return made = _Model();
          },
        ),
      );
      await pumpEventQueue();
      final events = <String>[];
      final removal = cache.closeForRemoval(
        'a.litertlm',
        () async => events.add('removed, closed: ${made?.isClosed}'),
      );
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'the removal waits for the build');

      gate.complete();
      expect(await building, same(made));
      await removal;
      expect(events, ['removed, closed: true']);
      expect(cache.model, isNull);
    });

    test('a caller arriving during the removal resolves its request once '
        'the removal has ended', () async {
      final cache = InferenceModelCache();
      await cache.obtain(() => request('a'));
      var active = 'a';
      final removing = Completer<void>();
      final removal = cache.closeForRemoval('a.litertlm', () async {
        await removing.future;
        // What an uninstall changes: the file's model is no longer active.
        active = 'b';
      });
      await pumpEventQueue();

      final next = cache.obtain(() => request(active));
      await pumpEventQueue();
      expect(built, ['a/1024'], reason: 'no build while the file is removed');

      removing.complete();
      await removal;
      await next;
      expect(built, ['a/1024', 'b/1024']);
    });

    test('waits for a close a rebuild started on the file', () async {
      final cache = InferenceModelCache();
      final teardown = Completer<void>();
      await cache.obtain(
        () => request(
          'a',
          build: () async {
            built.add('a/1024');
            return _Model(onClose: () => teardown.future);
          },
        ),
      );
      // Another model is active: the rebuild closes 'a' and forgets it.
      final rebuild = cache.obtain(() => request('b'));
      await pumpEventQueue();

      var removed = false;
      final removal = cache.closeForRemoval(
        'a.litertlm',
        () async => removed = true,
      );
      await pumpEventQueue();
      expect(removed, isFalse, reason: "'a' is still closing");

      teardown.complete();
      await removal;
      expect(removed, isTrue);
      await rebuild;
      expect(built, ['a/1024', 'b/1024']);
    });

    test('a close past the deadline fails the removal before it runs, and '
        'so does a retry while that close still runs', () async {
      final cache = InferenceModelCache(
        ModelCloseGate(const Duration(milliseconds: 50)),
      );
      final teardown = Completer<void>();
      await cache.obtain(
        () => request(
          'a',
          build: () async => _Model(onClose: () => teardown.future),
        ),
      );
      var removals = 0;

      await expectLater(
        cache.closeForRemoval('a.litertlm', () async => removals++),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        cache.closeForRemoval('a.litertlm', () async => removals++),
        throwsA(isA<TimeoutException>()),
      );
      expect(removals, 0);

      teardown.complete();
      await pumpEventQueue();
      await cache.closeForRemoval('a.litertlm', () async => removals++);
      expect(removals, 1);
    });

    test('a removal that fails leaves builds free', () async {
      final cache = InferenceModelCache();
      await cache.obtain(() => request('a'));

      await expectLater(
        cache.closeForRemoval(
          'a.litertlm',
          () async => throw StateError('file in use'),
        ),
        throwsStateError,
      );

      final next = await cache
          .obtain(() => request('a'))
          .timeout(const Duration(seconds: 1));
      expect(next.isClosed, isFalse);
      expect(built, ['a/1024', 'a/1024']);
    });

    test('a close of another file\'s model does not hold the removal, even '
        'past its deadline', () async {
      final cache = InferenceModelCache(
        ModelCloseGate(const Duration(milliseconds: 50)),
      );
      final teardown = Completer<void>();
      await cache.obtain(
        () => request(
          'a',
          build: () async => _Model(onClose: () => teardown.future),
        ),
      );
      // Another model is active: the rebuild starts closing 'a', which hangs.
      await expectLater(
        cache.obtain(() => request('b')),
        throwsA(isA<TimeoutException>()),
      );

      var removed = false;
      await cache.closeForRemoval('c.litertlm', () async => removed = true);

      expect(removed, isTrue);
      teardown.complete();
    });

    test('removals run one at a time, and builds wait for the last', () async {
      final cache = InferenceModelCache();
      await cache.obtain(() => request('a'));
      final first = Completer<void>();
      final second = Completer<void>();
      final events = <String>[];
      final removal1 = cache.closeForRemoval('x.litertlm', () async {
        events.add('1 start');
        await first.future;
        events.add('1 end');
      });
      final removal2 = cache.closeForRemoval('y.litertlm', () async {
        events.add('2 start');
        await second.future;
        events.add('2 end');
      });
      await pumpEventQueue();
      expect(events, ['1 start']);

      first.complete();
      await removal1;
      await pumpEventQueue();
      expect(events, ['1 start', '1 end', '2 start']);
      final next = cache.obtain(() => request('a', maxTokens: 2048));
      await pumpEventQueue();
      expect(built, ['a/1024'], reason: 'the second removal holds builds');

      second.complete();
      await removal2;
      await next;
      expect(built, ['a/1024', 'a/2048']);
    });

    test(
      'a caller asking for the model being built while its file is '
      'removed waits for the removal instead of sharing that build',
      () async {
        final cache = InferenceModelCache();
        final gate = Completer<void>();
        var active = 'a';
        final building = cache.obtain(
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
        final removal = cache.closeForRemoval(
          'a.litertlm',
          () async => active = 'b',
        );
        await pumpEventQueue();
        final sharer = cache.obtain(() => request(active));
        await pumpEventQueue();

        gate.complete();
        final first = await building;
        await removal;
        final second = await sharer;

        expect(second, isNot(same(first)));
        expect(built, ['a/1024', 'b/1024']);
      },
    );
  });

  test('every knob the cache compares reaches the engine', () {
    // Each set to something other than its default, so a knob left out of
    // runtimeConfigFor reads back as the default and fails here.
    const params = ActiveModelParams(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      preferredVisionBackend: PreferredBackend.cpu,
      preferredAudioBackend: PreferredBackend.npu,
      supportImage: true,
      supportAudio: true,
      maxNumImages: 3,
      enableSpeculativeDecoding: true,
      activationDataType: ActivationDataType.float32,
      maxConcurrentSessions: 2,
      loraRanks: [4, 8],
    );
    final config = runtimeConfigFor(params, modelPath: '/m.litertlm');
    expect(config.modelPath, '/m.litertlm');
    expect(config.maxTokens, 4096);
    expect(config.preferredBackend, PreferredBackend.gpu);
    expect(config.preferredVisionBackend, PreferredBackend.cpu);
    expect(config.preferredAudioBackend, PreferredBackend.npu);
    expect(config.supportImage, isTrue);
    expect(config.supportAudio, isTrue);
    expect(config.maxNumImages, 3);
    expect(config.enableSpeculativeDecoding, isTrue);
    expect(config.activationDataType, ActivationDataType.float32);
    expect(config.maxConcurrentSessions, 2);
    expect(config.loraRanks, [4, 8]);
  });

  test('a model the cache cannot watch is closed, not leaked', () async {
    final cache = InferenceModelCache();
    final model = _Model(listenerError: UnsupportedError('no listeners'));
    await expectLater(
      cache.obtain(() => request('a', build: () async => model)),
      throwsUnsupportedError,
    );
    expect(model.closes, 1);
    expect(cache.model, isNull);

    await cache.obtain(() => request('a'));
    expect(built, ['a/1024']);
  });
}

class _Model implements InferenceModel {
  _Model({this.onClose, this.listenerError});

  /// The teardown [close] waits for, when the test holds one open.
  final Future<void> Function()? onClose;

  /// Thrown by [addCloseListener], as a third-party model might.
  final Object? listenerError;

  final _listeners = <void Function()>[];
  bool _closed = false;
  int closes = 0;

  @override
  bool get isClosed => _closed;

  @override
  void addCloseListener(void Function() listener) {
    if (listenerError case final error?) throw error;
    _listeners.add(listener);
  }

  /// Closes without firing the listeners, as an engine whose listener fires
  /// late would.
  @override
  Future<void> close() async {
    _closed = true;
    closes++;
    await onClose?.call();
  }

  void fireLate() {
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
