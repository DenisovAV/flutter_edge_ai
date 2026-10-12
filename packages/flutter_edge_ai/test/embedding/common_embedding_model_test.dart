// CommonEmbeddingModel, the facade every core-built embedder is (R5 §4.3,
// §10.1 "Facade"): validation order, failed futures instead of throws, the two
// media permits, embedAll's window / cancel / fail-fast, the per-reply
// dimension check, close semantics and W6 — over a scripted host.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_test/flutter_test.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);
final _garbage = Uint8List.fromList([1, 2, 3, 4, 5]);

final class _Call {
  _Call(this.input, this.taskType);
  final EmbeddingInput input;
  final TaskType taskType;
  final reply = Completer<List<double>>();
}

/// A host whose replies the test hands out one by one ([autoReply] false), or
/// that answers every request at once with a vector of [replyLength].
final class _FakeHost implements EmbeddingHost {
  _FakeHost({
    EmbeddingPassInfo? info,
    Set<EmbeddingModality>? modalities,
    this.autoReply = true,
    this.replyLength = 2,
    this.failPendingOnClose = true,
  }) : info = info ?? const EmbeddingPassInfo(dimension: 2, maxInputTokens: 32),
       modalities = modalities ?? const {EmbeddingModality.text};

  @override
  final EmbeddingPassInfo info;
  @override
  final Set<EmbeddingModality> modalities;
  final bool autoReply;
  final int replyLength;

  /// False: requests in flight keep running through a close, as they do in
  /// the real hosts (the one in flight finishes).
  final bool failPendingOnClose;
  final calls = <_Call>[];
  final died = Completer<String>();
  final closeGate = Completer<void>();
  Object? closeError;
  bool closeCalled = false;
  bool closed = false;

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) {
    final call = _Call(input, taskType);
    calls.add(call);
    if (autoReply) {
      call.reply.complete(List<double>.filled(replyLength, 0.5));
    }
    return call.reply.future;
  }

  @override
  Future<String> get unexpectedExit => died.future;

  @override
  Future<void> close() async {
    closeCalled = true;
    for (final call in failPendingOnClose ? calls : const <_Call>[]) {
      if (!call.reply.isCompleted) {
        call.reply.completeError(const EmbedderClosedException());
      }
    }
    await closeGate.future;
    closed = true;
    final error = closeError;
    if (error != null) throw error;
  }
}

_FakeHost _imageHost({bool autoReply = true, bool failPendingOnClose = true}) =>
    _FakeHost(
      autoReply: autoReply,
      failPendingOnClose: failPendingOnClose,
      info: EmbeddingPassInfo(
        dimension: 2,
        modalities: const {EmbeddingModality.text, EmbeddingModality.image},
        imageFormats: {EncodedMediaFormat.jpeg},
      ),
      modalities: const {EmbeddingModality.text, EmbeddingModality.image},
    );

Future<void> _settle() => pumpEventQueue();

void main() {
  group('what the model reports', () {
    test('dimension, modalities, limit and backend come from the host', () {
      final model = CommonEmbeddingModel.withHost(
        _imageHost(),
        activeBackend: PreferredBackend.cpu,
      );
      expect(model.dimension, 2);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      expect(model.maxInputTokens, isNull);
      expect(model.activeBackend, PreferredBackend.cpu);
      expect(model.isClosed, isFalse);
    });
  });

  group('validation (§4.3), before anything is sent', () {
    test('1. a closed model refuses before any other check', () async {
      final fake = _FakeHost()..closeGate.complete();
      final model = CommonEmbeddingModel.withHost(fake);
      await model.close();

      await expectLater(
        model.embed(EmbeddingInput.image(_garbage), taskType: TaskType.none),
        throwsA(isA<EmbedderClosedException>()),
      );
      expect(fake.calls, isEmpty);
    });

    test('2. a modality the model was not loaded with', () async {
      final fake = _FakeHost();
      final model = CommonEmbeddingModel.withHost(fake);

      await expectLater(
        model.embed(EmbeddingInput.image(_garbage), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingModalityNotLoadedException>()
              .having((e) => e.modality, 'modality', EmbeddingModality.image)
              .having((e) => e.loaded, 'loaded', {EmbeddingModality.text})
              .having((e) => e.message, 'message', contains('supportImage')),
        ),
      );
      expect(fake.calls, isEmpty);
    });

    test(
      'text sent to a model without a text tower names no fake option',
      () async {
        final fake = _FakeHost(
          info: EmbeddingPassInfo(
            dimension: 2,
            modalities: const {EmbeddingModality.image},
            imageFormats: {EncodedMediaFormat.jpeg},
          ),
          modalities: const {EmbeddingModality.image},
        );
        final model = CommonEmbeddingModel.withHost(fake);
        await expectLater(
          model.embed(EmbeddingInput.text('q'), taskType: TaskType.none),
          throwsA(
            isA<EmbeddingModalityNotLoadedException>().having(
              (e) => e.message,
              'message',
              allOf(isNot(contains('supportText')), contains('no text tower')),
            ),
          ),
        );
      },
    );

    test('3. several modalities on an engine without combinedInputs '
        '(the D17 gate)', () async {
      final fake = _imageHost();
      final model = CommonEmbeddingModel.withHost(fake);
      final combined = debugCombinedEmbeddingInput(
        text: 'a cat',
        images: [_garbage],
      );

      await expectLater(
        model.embed(combined, taskType: TaskType.none),
        throwsA(
          isA<UnsupportedEmbeddingCombinationException>().having(
            (e) => e.requested,
            'requested',
            {EmbeddingModality.text, EmbeddingModality.image},
          ),
        ),
      );
      expect(fake.calls, isEmpty);
    });

    test('a combined input passes the gate when the engine combines', () async {
      final fake = _FakeHost(
        info: EmbeddingPassInfo(
          dimension: 2,
          modalities: const {EmbeddingModality.text, EmbeddingModality.image},
          imageFormats: {EncodedMediaFormat.jpeg},
          combinedInputs: true,
        ),
        modalities: const {EmbeddingModality.text, EmbeddingModality.image},
      );
      final model = CommonEmbeddingModel.withHost(fake);
      await model.embed(
        debugCombinedEmbeddingInput(text: 'a cat', images: [_jpeg]),
        taskType: TaskType.none,
      );
      expect(fake.calls, hasLength(1));
    });

    test('4. a container the engine does not decode', () async {
      final fake = _imageHost();
      final model = CommonEmbeddingModel.withHost(fake);

      await expectLater(
        model.embed(EmbeddingInput.image(_png), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>()
              .having((e) => e.detected, 'detected', EncodedMediaFormat.png)
              .having((e) => e.accepted, 'accepted', {EncodedMediaFormat.jpeg}),
        ),
      );
      await expectLater(
        model.embed(EmbeddingInput.image(_garbage), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>().having(
            (e) => e.detected,
            'detected',
            isNull,
          ),
        ),
      );
      expect(fake.calls, isEmpty);
    });

    test('an accepted container goes through', () async {
      final fake = _imageHost();
      final model = CommonEmbeddingModel.withHost(fake);
      await model.embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none);
      expect(fake.calls.single.input.images.single, _jpeg);
    });

    test('every failure is a failed future, never a synchronous throw', () {
      final model = CommonEmbeddingModel.withHost(_FakeHost());
      late Future<List<double>> one;
      late Future<List<List<double>>> all;
      expect(
        () => one = model.embed(
          EmbeddingInput.image(_jpeg),
          taskType: TaskType.none,
        ),
        returnsNormally,
      );
      expect(
        () => all = model.embedAll([
          EmbeddingInput.image(_jpeg),
        ], taskType: TaskType.none),
        returnsNormally,
      );
      expect(one, throwsA(isA<EmbeddingModalityNotLoadedException>()));
      expect(all, throwsA(isA<EmbeddingModalityNotLoadedException>()));
    });
  });

  group('admission: two model-wide media permits', () {
    test('a third media request waits; text is never held', () async {
      final fake = _imageHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);

      final media = [
        for (var i = 0; i < 3; i++)
          model.embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none),
      ];
      await _settle();
      expect(fake.calls, hasLength(2));

      final text = model.embed(
        EmbeddingInput.text('q'),
        taskType: TaskType.none,
      );
      await _settle();
      expect(fake.calls, hasLength(3), reason: 'text bypasses the permits');
      expect(fake.calls.last.input.text, 'q');

      fake.calls[0].reply.complete([0, 0]);
      await _settle();
      expect(fake.calls, hasLength(4), reason: 'a freed permit admits one');
      for (final call in fake.calls) {
        if (!call.reply.isCompleted) call.reply.complete([0, 0]);
      }
      await Future.wait([...media, text]);
    });

    test('a failed request frees its permit', () async {
      final fake = _imageHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final first = model.embed(
        EmbeddingInput.image(_jpeg),
        taskType: TaskType.none,
      );
      unawaited(first.then((_) {}, onError: (_) {}));
      model
          .embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none)
          .ignore();
      model
          .embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none)
          .ignore();
      await _settle();
      expect(fake.calls, hasLength(2));

      fake.calls[0].reply.completeError(
        const EmbeddingEngineException('x', engine: 'E'),
      );
      await _settle();
      expect(fake.calls, hasLength(3));
    });

    test(
      'waiters fail with EmbedderClosedException when close begins',
      () async {
        // The two admitted requests stay in flight through the close, so the
        // waiter can only fail because the close failed it — not because a
        // permit came free and the closed check caught it afterwards.
        final fake = _imageHost(autoReply: false, failPendingOnClose: false);
        final model = CommonEmbeddingModel.withHost(fake);
        final admitted = [
          for (var i = 0; i < 2; i++)
            model.embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none),
        ];
        for (final f in admitted) {
          f.ignore();
        }
        final waiting = model.embed(
          EmbeddingInput.image(_jpeg),
          taskType: TaskType.none,
        );
        await _settle();

        final closing = model.close();
        await expectLater(waiting, throwsA(isA<EmbedderClosedException>()));
        expect(fake.calls, hasLength(2), reason: 'the waiter never reached it');
        expect(
          fake.calls.every((c) => !c.reply.isCompleted),
          isTrue,
          reason: 'it failed while both permits were still held',
        );
        for (final call in fake.calls) {
          call.reply.complete([0, 0]);
        }
        fake.closeGate.complete();
        await closing;
      },
    );
  });

  group('per-reply dimension check', () {
    test('a vector of the wrong length fails the request', () async {
      final model = CommonEmbeddingModel.withHost(
        _FakeHost(replyLength: 3),
        engine: 'Fake',
      );
      await expectLater(
        model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'Fake')
              .having((e) => e.message, 'message', contains('length 3')),
        ),
      );
    });
  });

  group('embedAll', () {
    test('a media request still waiting for a permit is never sent once '
        'its embedAll was cancelled', () async {
      final fake = _imageHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      // Two single requests hold both media permits.
      final held = [
        for (var i = 0; i < 2; i++)
          model.embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none),
      ];
      final token = CancelToken();
      final all = model.embedAll(
        [EmbeddingInput.image(_jpeg), EmbeddingInput.image(_jpeg)],
        taskType: TaskType.none,
        cancelToken: token,
      );
      await _settle();
      expect(fake.calls, hasLength(2), reason: 'the batch waits for permits');

      token.cancel('test');
      await expectLater(all, throwsA(isA<EmbeddingCancelledException>()));
      for (final call in fake.calls) {
        call.reply.complete([0, 0]);
      }
      await Future.wait(held);
      await _settle();

      expect(
        fake.calls,
        hasLength(2),
        reason: 'the freed permits must not carry the cancelled batch out',
      );
      // And the permits came back: a new media request is admitted.
      model
          .embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none)
          .ignore();
      await _settle();
      expect(fake.calls, hasLength(3));
    });

    test('a media request still waiting for a permit is never sent once '
        'its embedAll failed', () async {
      final fake = _imageHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      // Two single requests hold both media permits, so the batch's image
      // waits while its text request runs — and fails.
      final held = [
        for (var i = 0; i < 2; i++)
          model.embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none),
      ];
      final all = model.embedAll([
        EmbeddingInput.text('fails'),
        EmbeddingInput.image(_jpeg),
      ], taskType: TaskType.none);
      await _settle();
      expect(fake.calls, hasLength(3), reason: 'two held images + the text');
      final textCall = fake.calls.firstWhere((c) => c.input.text == 'fails');

      textCall.reply.completeError(
        const EmbeddingEngineException('boom', engine: 'E'),
      );
      await expectLater(all, throwsA(isA<EmbeddingEngineException>()));
      for (final call in fake.calls) {
        if (!call.reply.isCompleted) call.reply.complete([0, 0]);
      }
      await Future.wait(held);
      await _settle();
      expect(
        fake.calls.where((c) => c.input.images.isNotEmpty),
        hasLength(2),
        reason: 'the failed batch\'s image never reached the host',
      );
    });

    List<EmbeddingInput> texts(int n) => [
      for (var i = 0; i < n; i++) EmbeddingInput.text('t$i'),
    ];

    test('at most two outstanding; results in input order', () async {
      final fake = _FakeHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final all = model.embedAll(texts(5), taskType: TaskType.clustering);

      await _settle();
      expect(fake.calls, hasLength(2));
      // Answer out of order: the second request first.
      fake.calls[1].reply.complete([1, 1]);
      await _settle();
      expect(fake.calls, hasLength(3));
      fake.calls[0].reply.complete([0, 0]);
      await _settle();
      expect(fake.calls, hasLength(4));
      for (var i = 2; i < 5; i++) {
        await _settle();
        fake.calls[i].reply.complete([i.toDouble(), i.toDouble()]);
      }

      expect(await all, [
        [0, 0],
        [1, 1],
        [2, 2],
        [3, 3],
        [4, 4],
      ]);
      expect(fake.calls.map((c) => c.taskType).toSet(), {TaskType.clustering});
    });

    test(
      'the inputs are read once: a list the caller changes afterwards '
      'neither smuggles in an unvalidated input nor hangs the call',
      () async {
        final fake = _FakeHost();
        final model = CommonEmbeddingModel.withHost(fake);
        final inputs = [EmbeddingInput.text('a'), EmbeddingInput.text('b')];

        final all = model.embedAll(inputs, taskType: TaskType.none);
        // An image this text-only model would have refused.
        inputs.add(EmbeddingInput.image(_jpeg));

        final vectors = await all.timeout(const Duration(seconds: 5));
        expect(vectors, hasLength(2));
        expect(fake.calls.map((c) => c.input.text), ['a', 'b']);
      },
    );

    test('every input is validated before the first is sent', () async {
      final fake = _FakeHost();
      final model = CommonEmbeddingModel.withHost(fake);
      await expectLater(
        model.embedAll([
          EmbeddingInput.text('fine'),
          EmbeddingInput.image(_jpeg),
        ], taskType: TaskType.none),
        throwsA(isA<EmbeddingModalityNotLoadedException>()),
      );
      expect(fake.calls, isEmpty);
    });

    test(
      'cancel stops sending — text too — and drops what is outstanding',
      () async {
        final fake = _FakeHost(autoReply: false);
        final model = CommonEmbeddingModel.withHost(fake);
        final token = CancelToken();
        final all = model.embedAll(
          texts(5),
          taskType: TaskType.none,
          cancelToken: token,
        );
        await _settle();
        expect(fake.calls, hasLength(2));

        token.cancel('test');
        await expectLater(all, throwsA(isA<EmbeddingCancelledException>()));
        fake.calls[0].reply.complete([0, 0]);
        fake.calls[1].reply.complete([1, 1]);
        await _settle();
        expect(fake.calls, hasLength(2), reason: 'nothing sent after cancel');
      },
    );

    test('a cancel made after a reply was queued, before it was delivered, '
        'sends no more', () async {
      final fake = _FakeHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final token = CancelToken();
      final all = model.embedAll(
        texts(5),
        taskType: TaskType.none,
        cancelToken: token,
      );
      final fails = expectLater(
        all,
        throwsA(isA<EmbeddingCancelledException>()),
      );
      await _settle();
      // The reply's delivery is queued first; the cancel's own notification
      // is queued behind it. The facade must still see the cancel when the
      // reply arrives and decide not to send the next request.
      fake.calls[0].reply.complete([0, 0]);
      token.cancel('before delivery');
      await _settle();

      await fails;
      expect(fake.calls, hasLength(2));
      fake.calls[1].reply.complete([1, 1]);
    });

    test('replies that arrive after a cancel are dropped quietly', () async {
      final fake = _FakeHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final token = CancelToken();
      final all = model.embedAll(
        texts(2),
        taskType: TaskType.none,
        cancelToken: token,
      );
      await _settle();
      token.cancel('test');
      await expectLater(all, throwsA(isA<EmbeddingCancelledException>()));

      // Every outstanding request now finishes; completing the call a second
      // time would be an unhandled StateError, which fails this test.
      fake.calls[0].reply.complete([0, 0]);
      fake.calls[1].reply.complete([1, 1]);
      await _settle();
    });

    test('a long-lived CancelToken keeps nothing of a finished call', () async {
      // The token's listener outlives the call when the token is never
      // cancelled; it must hold a link that the call clears when it settles,
      // not the call's results.
      final fake = _FakeHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final token = CancelToken();
      expect(debugLiveEmbedAllCancelLinks(), 0);

      final ok = model.embedAll(
        [EmbeddingInput.text('a')],
        taskType: TaskType.none,
        cancelToken: token,
      );
      await _settle();
      expect(debugLiveEmbedAllCancelLinks(), 1);
      fake.calls.last.reply.complete([0, 0]);
      await ok;
      expect(debugLiveEmbedAllCancelLinks(), 0, reason: 'cleared on success');

      final failing = model.embedAll(
        [EmbeddingInput.text('b')],
        taskType: TaskType.none,
        cancelToken: token,
      );
      await _settle();
      fake.calls.last.reply.completeError(
        const EmbeddingEngineException('x', engine: 'E'),
      );
      await expectLater(failing, throwsA(isA<EmbeddingEngineException>()));
      expect(debugLiveEmbedAllCancelLinks(), 0, reason: 'cleared on failure');

      final cancelled = model.embedAll(
        [EmbeddingInput.text('c')],
        taskType: TaskType.none,
        cancelToken: token,
      );
      await _settle();
      token.cancel('test');
      await expectLater(cancelled, throwsA(isA<EmbeddingCancelledException>()));
      expect(debugLiveEmbedAllCancelLinks(), 0, reason: 'cleared on cancel');
      fake.calls.last.reply.complete([0, 0]);
    });

    test('an already-cancelled token sends nothing', () async {
      final fake = _FakeHost();
      final model = CommonEmbeddingModel.withHost(fake);
      final token = CancelToken()..cancel('before');
      await expectLater(
        model.embedAll(texts(2), taskType: TaskType.none, cancelToken: token),
        throwsA(isA<EmbeddingCancelledException>()),
      );
      expect(fake.calls, isEmpty);
    });

    test('the first failure fails the call and stops sending', () async {
      final fake = _FakeHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      final all = model.embedAll(texts(5), taskType: TaskType.none);
      await _settle();

      fake.calls[0].reply.completeError(
        const EmbeddingInputTooLongException('long', maxInputTokens: 4),
      );
      await expectLater(all, throwsA(isA<EmbeddingInputTooLongException>()));
      fake.calls[1].reply.complete([1, 1]);
      await _settle();
      expect(fake.calls, hasLength(2));
    });

    test('a refused input is named by its index', () async {
      final model = CommonEmbeddingModel.withHost(_imageHost());
      await expectLater(
        model.embedAll([
          EmbeddingInput.text('fine'),
          EmbeddingInput.image(_jpeg),
          EmbeddingInput.image(_png),
        ], taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>()
              .having((e) => e.message, 'message', startsWith('Input 2 of 3:'))
              .having((e) => e.detected, 'detected', EncodedMediaFormat.png),
        ),
      );
      final textOnly = CommonEmbeddingModel.withHost(_FakeHost());
      await expectLater(
        textOnly.embedAll([
          EmbeddingInput.text('fine'),
          EmbeddingInput.image(_jpeg),
        ], taskType: TaskType.none),
        throwsA(
          isA<EmbeddingModalityNotLoadedException>().having(
            (e) => e.message,
            'message',
            startsWith('Input 1 of 2:'),
          ),
        ),
      );
    });

    test(
      'no inputs on a closed model still fails as closed (§4.3 step 1)',
      () async {
        final fake = _FakeHost()..closeGate.complete();
        final model = CommonEmbeddingModel.withHost(fake);
        await model.close();
        await expectLater(
          model.embedAll(const [], taskType: TaskType.none),
          throwsA(isA<EmbedderClosedException>()),
        );
      },
    );

    test('no inputs, no requests', () async {
      final fake = _FakeHost();
      expect(
        await CommonEmbeddingModel.withHost(
          fake,
        ).embedAll(const [], taskType: TaskType.none),
        isEmpty,
      );
      expect(fake.calls, isEmpty);
    });
  });

  group('close', () {
    test('closes the host; listeners fire after the teardown, once', () async {
      final fake = _FakeHost();
      final model = CommonEmbeddingModel.withHost(fake);
      var fired = 0;
      var hostClosedWhenFired = false;
      model.addCloseListener(() {
        fired++;
        hostClosedWhenFired = fake.closed;
      });

      final first = model.close();
      final second = model.close();
      expect(model.isClosed, isTrue, reason: 'closed from the first call');
      await _settle();
      expect(fired, 0, reason: 'the teardown has not finished');

      fake.closeGate.complete();
      await first;
      await second;
      expect(fired, 1);
      expect(hostClosedWhenFired, isTrue);
    });

    test('a host-close failure reaches the caller; a listener that also '
        'throws is printed, not swapped in; listeners still fire', () async {
      final fake = _FakeHost()
        ..closeError = StateError('host close failed')
        ..closeGate.complete();
      final model = CommonEmbeddingModel.withHost(fake);
      var fired = false;
      model.addCloseListener(() {
        fired = true;
        throw StateError('listener failed');
      });

      final printed = <String>[];
      Object? caught;
      await runZoned(
        () async {
          try {
            await model.close();
          } catch (e) {
            caught = e;
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect('$caught', contains('host close failed'));
      expect(fired, isTrue);
      expect(printed.join('\n'), contains('listener failed'));
      expect(model.isClosed, isTrue);
    });

    test('a later close waits for the same teardown', () async {
      final fake = _FakeHost();
      final model = CommonEmbeddingModel.withHost(fake);
      unawaited(model.close());
      var laterDone = false;
      unawaited(model.close().then((_) => laterDone = true));
      await _settle();
      expect(laterDone, isFalse);
      fake.closeGate.complete();
      await _settle();
      expect(laterDone, isTrue);
    });
  });

  group('W6: the host dies under the model', () {
    test('the model turns closed and tells its listeners', () async {
      final fake = _imageHost(autoReply: false);
      final model = CommonEmbeddingModel.withHost(fake);
      var fired = 0;
      model.addCloseListener(() => fired++);
      for (var i = 0; i < 2; i++) {
        model
            .embed(EmbeddingInput.image(_jpeg), taskType: TaskType.none)
            .ignore();
      }
      final waiting = model.embed(
        EmbeddingInput.image(_jpeg),
        taskType: TaskType.none,
      );
      await _settle();
      final waiterFails = expectLater(
        waiting,
        throwsA(isA<EmbedderClosedException>()),
      );

      fake.died.complete('worker crashed');
      await _settle();

      expect(model.isClosed, isTrue);
      expect(fired, 1);
      await waiterFails;
      await expectLater(
        model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
        throwsA(
          isA<EmbedderClosedException>().having(
            (e) => e.message,
            'message',
            contains('worker crashed'),
          ),
        ),
      );
    });
  });

  group('deprecated forwarders over the facade', () {
    test('generateEmbedding on a closed model fails as a future', () async {
      final fake = _FakeHost()..closeGate.complete();
      final model = CommonEmbeddingModel.withHost(fake);
      await model.close();
      // ignore: deprecated_member_use_from_same_package
      final result = model.generateEmbedding('x');
      await expectLater(result, throwsA(isA<EmbedderClosedException>()));
    });
  });
}
