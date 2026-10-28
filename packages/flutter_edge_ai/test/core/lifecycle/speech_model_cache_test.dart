// SpeechModelCache: the STT/TTS counterpart of InferenceModelCache — reuse by
// key, one build at a time, and closeForRemoval for an uninstall (B89).
//
// Run: flutter test test/core/lifecycle/speech_model_cache_test.dart

import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_edge_ai/src/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/src/lifecycle/speech_model_cache.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model {
  _Model(this.key, {this.onClose});

  final String key;
  final Future<void> Function()? onClose;
  final _listeners = <VoidCallback>[];
  int closes = 0;
  bool get isClosed => closes > 0;

  Future<void> close() async {
    closes++;
    await onClose?.call();
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

SpeechModelCache<_Model, String> _cache({
  ModelCloseGate? gate,
  SpeechModelReuse Function(String, String)? decide,
}) => SpeechModelCache<_Model, String>(
  close: (m) => m.close(),
  addCloseListener: (m, l) => m._listeners.add(l),
  decide: decide,
  closeGate: gate,
);

void main() {
  late List<String> built;

  setUp(() => built = []);

  Future<SpeechModelRequest<_Model, String>> request(
    String key, {
    Set<String>? files,
    Future<_Model> Function()? build,
  }) async => (
    key: key,
    files: files ?? {'$key.tflite'},
    label: key,
    build:
        build ??
        () async {
          built.add(key);
          return _Model(key);
        },
  );

  test('the same key reuses the model, and onReuse sees it', () async {
    final cache = _cache();
    final first = await cache.obtain(() => request('a'));
    _Model? reused;
    final second = await cache.obtain(
      () => request('a'),
      onReuse: (m) => reused = m,
    );
    expect(second, same(first));
    expect(reused, same(first));
    expect(built, ['a']);
  });

  test('another key closes the model and builds a new one', () async {
    final cache = _cache();
    final first = await cache.obtain(() => request('a'));
    final second = await cache.obtain(() => request('b'));
    expect(first.closes, 1);
    expect(second.key, 'b');
    expect(cache.model, same(second));
  });

  test('two callers asking for the same key share one build', () async {
    final cache = _cache();
    final results = await Future.wait([
      cache.obtain(() => request('a')),
      cache.obtain(() => request('a')),
    ]);
    expect(results[0], same(results[1]));
    expect(built, ['a']);
  });

  test('a caller asking for another key waits for the build in flight, '
      'then builds its own', () async {
    final cache = _cache();
    final gate = Completer<void>();
    final first = cache.obtain(
      () => request(
        'a',
        build: () async {
          await gate.future;
          built.add('a');
          return _Model('a');
        },
      ),
    );
    final second = cache.obtain(() => request('b'));
    await pumpEventQueue();
    gate.complete();
    final a = await first;
    final b = await second;
    expect(b.key, 'b');
    expect(a.closes, 1);
    expect(built, ['a', 'b']);
  });

  test('a refusing rule throws without closing the model', () async {
    final cache = _cache(
      decide: (cached, requested) => cached == requested
          ? SpeechModelReuse.reuse
          : throw StateError('other language'),
    );
    final first = await cache.obtain(() => request('a'));
    await expectLater(
      cache.obtain(() => request('b')),
      throwsA(isA<StateError>()),
    );
    expect(first.isClosed, isFalse);
    expect(cache.model, same(first));
  });

  test('a failed build leaves nothing cached, and the next call builds '
      'again', () async {
    final cache = _cache();
    await expectLater(
      cache.obtain(
        () => request('a', build: () async => throw StateError('boom')),
      ),
      throwsStateError,
    );
    expect(cache.model, isNull);
    final next = await cache.obtain(() => request('a'));
    expect(next.key, 'a');
  });

  test('a model its owner closed is forgotten, and the next call builds '
      'again', () async {
    final cache = _cache();
    final first = await cache.obtain(() => request('a'));
    await first.close();
    final second = await cache.obtain(() => request('a'));
    expect(second, isNot(same(first)));
  });

  group('closeForRemoval', () {
    test('closes the model built from the files before the removal runs, '
        'and the next call builds a new one', () async {
      final cache = _cache();
      final model = await cache.obtain(() => request('a'));
      bool? closedAtRemoval;

      await cache.closeForRemoval({'a.tflite'}, () async {
        closedAtRemoval = model.isClosed;
      });

      expect(closedAtRemoval, isTrue);
      expect(model.closes, 1);
      expect(cache.model, isNull);
      final again = await cache.obtain(() => request('a'));
      expect(again, isNot(same(model)));
    });

    test('leaves a model built from other files open and cached', () async {
      final cache = _cache();
      final model = await cache.obtain(() => request('a'));
      var removed = false;

      await cache.closeForRemoval({'b.tflite'}, () async => removed = true);

      expect(removed, isTrue);
      expect(model.isClosed, isFalse);
      expect(cache.model, same(model));
    });

    test('leaves a model built from explicit paths (no files) open', () async {
      final cache = _cache();
      final model = await cache.obtain(
        () => request('a', files: const <String>{}),
      );

      await cache.closeForRemoval({'a.tflite'}, () async {});

      expect(model.isClosed, isFalse);
    });

    test('closes a build of the files in flight once it ends, before the '
        'removal runs', () async {
      final cache = _cache();
      final gate = Completer<void>();
      final building = cache.obtain(
        () => request(
          'a',
          build: () async {
            await gate.future;
            return _Model('a');
          },
        ),
      );
      await pumpEventQueue();
      bool? closedAtRemoval;
      final removal = cache.closeForRemoval({'a.tflite'}, () async {
        closedAtRemoval = (await building).isClosed;
      });
      gate.complete();
      await removal;
      final model = await building;
      expect(closedAtRemoval, isTrue);
      expect(model.closes, 1);
      expect(cache.model, isNull);
    });

    test('a caller arriving during the removal resolves its request once '
        'the removal has ended', () async {
      final cache = _cache();
      await cache.obtain(() => request('a'));
      final removing = Completer<void>();
      var installed = false;
      final removal = cache.closeForRemoval({
        'a.tflite',
      }, () => removing.future);
      await pumpEventQueue();
      final waiting = cache.obtain(() async {
        if (!installed) throw StateError('No active STT model set');
        return request('a');
      });
      await pumpEventQueue();
      installed = true;
      removing.complete();
      await removal;
      final next = await waiting;
      expect(next.isClosed, isFalse);
      expect(built, ['a', 'a']);
    });

    test('a close past the deadline fails the removal before it runs, and '
        'so does a retry while that close still runs', () async {
      final cache = _cache(
        gate: ModelCloseGate(const Duration(milliseconds: 50)),
      );
      final teardown = Completer<void>();
      await cache.obtain(
        () => request(
          'a',
          build: () async => _Model('a', onClose: () => teardown.future),
        ),
      );
      var removals = 0;

      await expectLater(
        cache.closeForRemoval({'a.tflite'}, () async => removals++),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        cache.closeForRemoval({'a.tflite'}, () async => removals++),
        throwsA(isA<TimeoutException>()),
      );
      expect(removals, 0);

      teardown.complete();
      await pumpEventQueue();
      await cache.closeForRemoval({'a.tflite'}, () async => removals++);
      expect(removals, 1);
    });

    test('a removal that fails leaves builds free', () async {
      final cache = _cache();
      await cache.obtain(() => request('a'));

      await expectLater(
        cache.closeForRemoval({
          'a.tflite',
        }, () async => throw StateError('file in use')),
        throwsStateError,
      );

      final next = await cache
          .obtain(() => request('a'))
          .timeout(const Duration(seconds: 1));
      expect(next.isClosed, isFalse);
    });
  });

  group('decideTtsReuse', () {
    test('reuses the same model and language', () {
      expect(
        decideTtsReuse(
          (name: 'm', language: 'english'),
          (name: 'm', language: 'english'),
        ),
        SpeechModelReuse.reuse,
      );
    });

    test('rebuilds for another model', () {
      expect(
        decideTtsReuse(
          (name: 'm', language: 'english'),
          (name: 'n', language: 'french'),
        ),
        SpeechModelReuse.rebuild,
      );
    });

    test('refuses the same model in another language', () {
      expect(
        () => decideTtsReuse(
          (name: 'm', language: 'english'),
          (name: 'm', language: 'french'),
        ),
        throwsStateError,
      );
    });

    test('normalizes the language', () {
      expect(normalizeTtsLanguage(null), 'english');
      expect(normalizeTtsLanguage('English'), 'english');
    });
  });
}
