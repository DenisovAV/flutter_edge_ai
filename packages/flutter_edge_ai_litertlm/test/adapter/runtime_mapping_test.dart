// The adapter's boundary with the runtime: core's types to the runtime's and
// back, and each runtime exception to the core exception an app has always
// caught.
//
// The decider SPI is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/runtime_mapping.dart';
import 'package:litertlm_dart/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every backend maps to the one of the same name and back', () {
    for (final backend in PreferredBackend.values) {
      expect(backend.toRuntime.name, backend.name);
      expect(backend.toRuntime.toCore, backend);
    }
    expect(Backend.values.length, PreferredBackend.values.length);
  });

  test('every activation type maps to the one of the same name and back', () {
    for (final type in ActivationDataType.values) {
      expect(type.toRuntime.name, type.name);
      expect(type.toRuntime.toCore, type);
    }
    expect(ActivationType.values.length, ActivationDataType.values.length);
  });

  test('a sampler keeps every value both ways', () {
    const resolved = ResolvedSampling(
      temperature: 0.6,
      topK: 20,
      topP: 0.95,
      randomSeed: 7,
    );
    expect(
      resolved.toRuntime,
      const Sampler(temperature: 0.6, topK: 20, topP: 0.95, randomSeed: 7),
    );
    const bundle = BundleSampler(temperature: 0.6, topP: 0.95);
    final core = bundle.toCore;
    expect(
      [core.temperature, core.topK, core.topP, core.randomSeed],
      [0.6, null, 0.95, null],
    );
  });

  test('a media order keeps each side', () {
    for (final images in MediaPosition.values) {
      for (final audio in MediaPosition.values) {
        final order = MultimodalOrder(images: images, audio: audio).toRuntime;
        expect(order.images.name, images.name);
        expect(order.audio.name, audio.name);
      }
    }
  });

  test('turn metrics keep every value', () {
    final metrics = const TurnMetrics(
      inputTokens: 1,
      outputTokens: 2,
      totalTokens: 3,
      timeToFirstTokenMs: 4,
      tokensPerSecond: 5,
      initTimeMs: 6,
    ).toCore;
    expect(
      [
        metrics.inputTokens,
        metrics.outputTokens,
        metrics.totalTokens,
        metrics.timeToFirstTokenMs,
        metrics.tokensPerSecond,
        metrics.initTimeMs,
      ],
      [1, 2, 3, 4.0, 5.0, 6.0],
    );
  });

  group('runtime errors become the core exceptions', () {
    test('a refused constraint is a ResponseFormatUnsupportedException', () {
      final mapped = mapRuntimeError(
        const ConstraintUnsupportedException('no'),
      );
      expect(
        mapped,
        isA<ResponseFormatUnsupportedException>().having(
          (e) => e.message,
          'message',
          'no',
        ),
      );
    });

    test('a cancelled scoring run is a DeciderCancelledException', () {
      expect(
        mapRuntimeError(const ScoringCancelledException('stop')),
        isA<DeciderCancelledException>(),
      );
    });

    test('anything else is passed through as is', () {
      final error = StateError('x');
      expect(mapRuntimeError(error), same(error));
    });

    test('a stream error is mapped and the chunks before it kept', () async {
      final controller = StreamController<String>();
      final got = <String>[];
      final done = mapRuntimeErrors(
        controller.stream,
      ).listen(got.add).asFuture<void>();
      controller
        ..add('a')
        ..addError(const ConstraintUnsupportedException('no'))
        ..close();
      await expectLater(
        done,
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
      expect(got, ['a']);
    });

    test('withCoreErrors maps a thrown runtime error', () async {
      await expectLater(
        withCoreErrors<void>(
          () async => throw const ScoringCancelledException('stop'),
        ),
        throwsA(isA<DeciderCancelledException>()),
      );
    });
  });

  test('a cancel token is seen through the signal', () async {
    final token = CancelToken();
    final signal = CancelTokenSignal(token);
    expect(signal.isCancelled, isFalse);
    token.cancel();
    expect(signal.isCancelled, isTrue);
    await signal.whenCancelled;
  });
}
