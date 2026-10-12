// The pure pieces both embedding hosts share (R5 §4): RequestLanes and the
// pump (W1-W3), checkLoadedPass (§4.2 step 5), and the failure wire (§4.7).

import 'dart:async';

import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/load_check.dart';
import 'package:flutter_edge_ai/src/embedding/request_lanes.dart';
import 'package:flutter_edge_ai/src/embedding/wire.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestLanes', () {
    test('oldest text first, then oldest media; FIFO within a lane', () {
      final lanes = RequestLanes<String>()
        ..add('m1', media: true)
        ..add('t1', media: false)
        ..add('m2', media: true)
        ..add('t2', media: false);

      expect(lanes.length, 4);
      expect(
        [for (var r = lanes.takeNext(); r != null; r = lanes.takeNext()) r],
        ['t1', 't2', 'm1', 'm2'],
      );
      expect(lanes.isEmpty, isTrue);
    });

    test('a text request filed later still overtakes queued media', () {
      final lanes = RequestLanes<String>()
        ..add('m1', media: true)
        ..add('m2', media: true);
      expect(lanes.takeNext(), 'm1');
      lanes.add('t1', media: false);
      expect(lanes.takeNext(), 't1');
      expect(lanes.takeNext(), 'm2');
    });

    test('drain empties both lanes', () {
      final lanes = RequestLanes<String>()
        ..add('m1', media: true)
        ..add('t1', media: false);
      expect(lanes.drain(), unorderedEquals(['t1', 'm1']));
      expect(lanes.isEmpty, isTrue);
    });
  });

  group('RequestPump', () {
    test('serves one request at a time, text lane first', () async {
      final served = <String>[];
      final gate = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      final pump = RequestPump<String>((r) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        served.add(r);
        if (r == 'first') await gate.future;
        inFlight--;
      });
      final done = pump.run();

      pump.file('first', media: false);
      await pumpEventQueue();
      pump
        ..file('m1', media: true)
        ..file('t1', media: false)
        ..file('m2', media: true)
        ..file('t2', media: false);
      gate.complete();
      await pumpEventQueue();
      pump.requestClose();
      await done;

      expect(served, ['first', 't1', 't2', 'm1', 'm2']);
      expect(maxInFlight, 1);
    });

    test(
      'close returns what has not started; the one in flight finishes',
      () async {
        final gate = Completer<void>();
        final finished = <String>[];
        final pump = RequestPump<String>((r) async {
          await gate.future;
          finished.add(r);
        });
        final done = pump.run();
        pump.file('a', media: false);
        await pumpEventQueue();
        pump
          ..file('b', media: false)
          ..file('c', media: true);

        final notStarted = pump.requestClose();
        expect(notStarted, ['b', 'c']);
        expect(pump.file('d', media: false), isFalse);

        gate.complete();
        await done;
        expect(finished, ['a']);
      },
    );

    test('a request filed after close is refused, not queued', () {
      final pump = RequestPump<String>((_) async {})..requestClose();
      expect(pump.file('late', media: false), isFalse);
      expect(pump.queued, 0);
    });

    test('yields through the host\'s yield before every request, and a close '
        'that lands during a yield starts nothing more', () async {
      // The inline host passes a MessageChannel yield on web (a nested zero
      // timer is clamped to >= 4 ms there); the isolate host keeps the zero
      // timer. Either way the pump re-checks for a close after the yield.
      final served = <String>[];
      var yields = 0;
      List<String>? notStarted;
      late final RequestPump<String> pump;
      pump = RequestPump<String>(
        (r) async => served.add(r),
        yieldToEventLoop: () async {
          yields++;
          if (yields == 2) notStarted = pump.requestClose();
        },
      );
      pump
        ..file('a', media: false)
        ..file('b', media: false)
        ..file('c', media: true);

      await pump.run();

      expect(served, ['a']);
      expect(yields, 2, reason: 'one yield per request, before it starts');
      expect(notStarted, ['b', 'c']);
    });
  });

  group('runTeardown', () {
    test('every step runs; the first error reaches the caller with its '
        'stack; later ones are printed', () async {
      final ran = <String>[];
      final printed = <String>[];
      Object? caught;
      StackTrace? caughtStack;
      await runZoned(
        () async {
          try {
            await runTeardown('closing the test embedder', [
              () {
                ran.add('a');
                throw StateError('first');
              },
              () async {
                ran.add('b');
                throw StateError('second');
              },
              () => ran.add('c'),
            ]);
          } catch (e, st) {
            caught = e;
            caughtStack = st;
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(ran, ['a', 'b', 'c']);
      expect('$caught', contains('first'));
      expect('$caughtStack', contains('host_parts_test'));
      expect(printed.join('\n'), contains('second'));
    });

    test('no error, nothing thrown or printed', () async {
      final ran = <int>[];
      await runTeardown('x', [() => ran.add(1), () async => ran.add(2)]);
      expect(ran, [1, 2]);
    });
  });

  group('checkLoadedPass', () {
    Set<EmbeddingModality> check(
      EmbeddingPassInfo info,
      Set<EmbeddingModality> declared,
    ) => checkLoadedPass(info, declared, engine: 'Fake', label: 'm.bin');

    test('text tower + nothing declared = text', () {
      expect(check(const EmbeddingPassInfo(dimension: 4), const {}), {
        EmbeddingModality.text,
      });
    });

    test('declared media the engine serves are added to text', () {
      final info = EmbeddingPassInfo(
        dimension: 4,
        modalities: const {EmbeddingModality.text, EmbeddingModality.image},
        imageFormats: {EncodedMediaFormat.jpeg},
      );
      expect(check(info, const {EmbeddingModality.image}), {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
    });

    test('media the engine serves but nobody declared are NOT added', () {
      final info = EmbeddingPassInfo(
        dimension: 4,
        modalities: const {EmbeddingModality.text, EmbeddingModality.image},
        imageFormats: {EncodedMediaFormat.jpeg},
      );
      expect(check(info, const {}), {EmbeddingModality.text});
    });

    test('a declared modality the engine lacks is refused, named', () {
      expect(
        () => check(const EmbeddingPassInfo(dimension: 4), const {
          EmbeddingModality.image,
        }),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'Fake')
              .having((e) => e.message, 'message', contains('images'))
              .having((e) => e.message, 'message', contains('m.bin')),
        ),
      );
    });

    test('a non-positive dimension is refused', () {
      expect(
        () => check(const EmbeddingPassInfo(dimension: 0), const {}),
        throwsA(isA<EmbeddingLoadException>()),
      );
    });

    test('image support without image formats is an engine bug', () {
      expect(
        () => check(
          const EmbeddingPassInfo(
            dimension: 4,
            modalities: {EmbeddingModality.text, EmbeddingModality.image},
          ),
          const {},
        ),
        throwsA(isA<EmbeddingLoadException>()),
      );
    });

    test('a model that would accept nothing is refused at load', () {
      // No text tower, and the medium it has was not declared.
      expect(
        () => check(
          EmbeddingPassInfo(
            dimension: 4,
            modalities: const {EmbeddingModality.image},
            imageFormats: {EncodedMediaFormat.jpeg},
          ),
          const {},
        ),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            allOf(contains('supportImage'), isNot(contains('supportText'))),
          ),
        ),
      );
    });

    test('a format listed under the other modality is an engine bug', () {
      expect(
        () => check(
          EmbeddingPassInfo(
            dimension: 4,
            modalities: const {EmbeddingModality.text, EmbeddingModality.image},
            imageFormats: {EncodedMediaFormat.jpeg, EncodedMediaFormat.wav},
          ),
          const {EmbeddingModality.image},
        ),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            contains('wav'),
          ),
        ),
      );
      expect(
        () => check(
          EmbeddingPassInfo(
            dimension: 4,
            modalities: const {EmbeddingModality.text, EmbeddingModality.audio},
            audioFormats: {EncodedMediaFormat.png},
          ),
          const {},
        ),
        throwsA(isA<EmbeddingLoadException>()),
      );
    });

    test('maxInputTokens must be positive when declared', () {
      for (final bad in [0, -1]) {
        expect(
          () => check(
            EmbeddingPassInfo(dimension: 4, maxInputTokens: bad),
            const {},
          ),
          throwsA(isA<EmbeddingLoadException>()),
          reason: '$bad',
        );
      }
      expect(
        check(const EmbeddingPassInfo(dimension: 4, maxInputTokens: 1), {}),
        {EmbeddingModality.text},
      );
    });

    test('audio support without audio formats is an engine bug', () {
      expect(
        () => check(
          const EmbeddingPassInfo(
            dimension: 4,
            modalities: {EmbeddingModality.audio},
          ),
          const {},
        ),
        throwsA(isA<EmbeddingLoadException>()),
      );
    });
  });

  group('EmbeddingFailure', () {
    EmbeddingException roundTrip(Object error, {bool loading = false}) =>
        EmbeddingFailure.fromError(
          error,
          engine: 'Fake',
          loading: loading,
        ).toException();

    test('only the host says "closed before it ran"', () {
      final e = EmbeddingFailure.closedBeforeRun(engine: 'Fake').toException();
      expect(e, isA<EmbedderClosedException>());
      expect(e.message, contains('before this request ran'));
    });

    test(
      'a pass that throws EmbedderClosedException did run: engine failure',
      () {
        // EmbedderClosedException promises the request never ran. A pass
        // throwing it mid-embed ran; reporting it as "closed" would invite a
        // retry of work that may have had effects, and hide the engine bug.
        expect(
          roundTrip(const EmbedderClosedException('pass said closed')),
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'Fake')
              .having(
                (e) => e.message,
                'message',
                contains('pass said closed'),
              ),
        );
      },
    );

    test(
      'a pass that throws EmbeddingLoadException mid-embed: engine failure',
      () {
        expect(
          roundTrip(
            const EmbeddingLoadException(
              'late',
              engine: 'Native',
              nativeCode: 7,
            ),
          ),
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'Native')
              .having((e) => e.nativeCode, 'code', 7),
        );
      },
    );

    test(
      'while loading, every kind is a load failure, engine and code kept',
      () {
        for (final error in <Object>[
          const EmbedderClosedException('c'),
          const EmbeddingInputTooLongException('t', maxInputTokens: 4),
          const EmbeddingEngineException('e', engine: 'Native', nativeCode: 3),
          const EmbeddingLoadException('l', engine: 'Native', nativeCode: 5),
          StateError('s'),
        ]) {
          expect(
            roundTrip(error, loading: true),
            isA<EmbeddingLoadException>(),
            reason: '$error',
          );
        }
        expect(
          roundTrip(
            const EmbeddingEngineException(
              'e',
              engine: 'Native',
              nativeCode: 3,
            ),
            loading: true,
          ),
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'Native')
              .having((e) => e.nativeCode, 'code', 3),
        );
      },
    );

    test('too long keeps both counts', () {
      expect(
        roundTrip(
          const EmbeddingInputTooLongException(
            'long',
            maxInputTokens: 8,
            actualTokens: 9,
          ),
        ),
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'max', 8)
            .having((e) => e.actualTokens, 'actual', 9)
            .having((e) => e.message, 'message', 'long'),
      );
      expect(
        roundTrip(
          const EmbeddingInputTooLongException('long', maxInputTokens: 8),
        ),
        isA<EmbeddingInputTooLongException>().having(
          (e) => e.actualTokens,
          'actual',
          isNull,
        ),
      );
    });

    test('engine keeps its engine name and native code', () {
      expect(
        roundTrip(
          const EmbeddingEngineException('x', engine: 'Native', nativeCode: 3),
        ),
        isA<EmbeddingEngineException>()
            .having((e) => e.engine, 'engine', 'Native')
            .having((e) => e.nativeCode, 'code', 3),
      );
    });

    test('a load failure keeps its engine name and native code', () {
      expect(
        roundTrip(
          const EmbeddingLoadException('x', engine: 'Native', nativeCode: 5),
          loading: true,
        ),
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'Native')
            .having((e) => e.nativeCode, 'code', 5),
      );
    });

    test('anything else becomes an engine failure carrying its text', () {
      expect(
        roundTrip(StateError('kaput')),
        isA<EmbeddingEngineException>()
            .having((e) => e.engine, 'engine', 'Fake')
            .having((e) => e.message, 'message', 'Bad state: kaput'),
      );
    });

    test('anything else while loading becomes a load failure', () {
      expect(
        roundTrip(StateError('kaput'), loading: true),
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          'Bad state: kaput',
        ),
      );
      expect(
        roundTrip(
          const EmbeddingEngineException('x', engine: 'Native'),
          loading: true,
        ),
        isA<EmbeddingLoadException>(),
      );
    });

    test('across the isolate the cause travels in the message', () {
      final e = roundTrip(
        const EmbeddingEngineException(
          'boom',
          engine: 'Native',
          cause: 'status 13: tensor allocation failed',
        ),
      );
      expect(e.message, 'boom (cause: status 13: tensor allocation failed)');
      expect(e.cause, isNull);

      final load = roundTrip(
        const EmbeddingLoadException('no load', engine: 'N', cause: 'dlopen'),
        loading: true,
      );
      expect(load.message, 'no load (cause: dlopen)');
    });

    test('inline, the cause stays an object and is not repeated', () {
      const original = EmbeddingEngineException(
        'boom',
        engine: 'Native',
        cause: 'detail',
      );
      final e = EmbeddingFailure.fromError(
        original,
        engine: 'Fake',
        causeInMessage: false,
      ).toException(cause: original.cause);
      expect(e.message, 'boom');
      expect(e.cause, 'detail');
      // Both hosts print the same line.
      expect(e.toString(), roundTrip(original).toString());
    });

    test('another EmbeddingException subtype names itself', () {
      final e = roundTrip(
        EmbeddingFormatNotSupportedException(
          'not a jpeg',
          modality: EmbeddingModality.image,
          detected: null,
          accepted: {EncodedMediaFormat.jpeg},
        ),
      );
      expect(e, isA<EmbeddingEngineException>());
      expect(e.message, 'EmbeddingFormatNotSupportedException: not a jpeg');
    });

    test('the cause is attached only where it is at hand', () {
      final failure = EmbeddingFailure.fromError(
        StateError('x'),
        engine: 'Fake',
      );
      expect(failure.toException().cause, isNull);
      expect(failure.toException(cause: 'native').cause, 'native');
    });
  });
}
