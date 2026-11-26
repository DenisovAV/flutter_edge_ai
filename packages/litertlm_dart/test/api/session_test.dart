// Kotlin's Session API over a fake handle: what each call hands the handle,
// the checks before it, and the native handle's input mapping.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart'
    show LiteRtLmFfiClient, engineForTest;
import 'package:litertlm_dart/litertlm_dart.dart' show LiteRtLmNativeException;
import 'package:litertlm_dart/src/api/session.dart';
import 'package:litertlm_dart/src/ffi/session_ffi.dart';
import 'package:test/test.dart';

class _Handle implements SessionHandle {
  final calls = <String>[];
  final clones = <_Handle>[];

  String _names(List<InputData> inputs) => [
    for (final i in inputs)
      switch (i) {
        TextInputData(:final text) => 'text:$text',
        ImageInputData(:final bytes) => 'image:${bytes.length}',
        AudioInputData(:final bytes) => 'audio:${bytes.length}',
      },
  ].join(',');

  @override
  Future<void> runPrefill(List<InputData> inputs) async =>
      calls.add('prefill(${_names(inputs)})');

  @override
  Future<String> runDecode() async {
    calls.add('decode');
    return 'four';
  }

  @override
  Future<String> generateContent(List<InputData> inputs) async {
    calls.add('generate(${_names(inputs)})');
    return 'six';
  }

  @override
  Stream<String> generateContentStream(List<InputData> inputs) {
    calls.add('stream(${_names(inputs)})');
    return Stream.fromIterable(['a', 'b']);
  }

  @override
  void cancelProcess() => calls.add('cancel');

  @override
  Future<SessionHandle> clone() async {
    final clone = _Handle();
    clones.add(clone);
    return clone;
  }

  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  test('each call reaches the handle; a clone is a session of its own; a '
      'closed session refuses', () async {
    final handle = _Handle();
    var engineClosed = false;
    final session = newSession(handle, () => engineClosed);
    await session.runPrefill([const InputData.text('2 + 2?')]);
    expect(await session.runDecode(), 'four');
    expect(
      await session.generateContent([const InputData.text('what?')]),
      'six',
    );
    expect(
      await session.generateContentStream([
        const InputData.text('go'),
      ]).toList(),
      ['a', 'b'],
    );
    final clone = await session.clone();
    await clone.runDecode();
    expect(handle.calls, [
      'prefill(text:2 + 2?)',
      'decode',
      'generate(text:what?)',
      'stream(text:go)',
    ]);
    expect(handle.clones.single.calls, ['decode']);
    await session.close();
    expect(handle.calls.last, 'close');
    expect(session.runDecode, throwsStateError);
    engineClosed = true;
    expect(clone.runDecode, throwsStateError);
  });

  test('empty inputs, images and audio are refused before the handle, with '
      "LiteRT-LM 0.20.0's reason for media", () {
    final handle = _Handle();
    final session = newSession(handle, () => false);
    for (final call in <void Function()>[
      () => session.runPrefill([]),
      () => session.generateContent([]),
      () => session.generateContentStream([]),
    ]) {
      expect(call, throwsArgumentError);
    }
    for (final (input, reason) in [
      (InputData.image(Uint8List(3)), 'Image must be preprocessed'),
      (InputData.audio(Uint8List(3)), 'Audio must be preprocessed'),
    ]) {
      for (final call in <void Function()>[
        () => session.runPrefill([const InputData.text('a'), input]),
        () => session.generateContent([input]),
        () => session.generateContentStream([input]),
      ]) {
        expect(
          call,
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
        );
      }
    }
    expect(handle.calls, isEmpty);
  });

  test('after cancelProcess, busy or idle, every call but close is a '
      'StateError naming the rule; the cancel reaches the handle even while '
      'the engine closes', () async {
    final handle = _Handle();
    var engineClosed = false;
    final session = newSession(handle, () => engineClosed);
    engineClosed = true;
    session.cancelProcess();
    engineClosed = false;
    expect(handle.calls, ['cancel']);
    for (final call in <Future<Object?> Function()>[
      () => session.runPrefill([const InputData.text('a')]),
      session.runDecode,
      () => session.generateContent([const InputData.text('a')]),
      () => session.generateContentStream([const InputData.text('a')]).toList(),
      session.clone,
    ]) {
      expect(
        call,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not support reusing a session after cancelProcess'),
          ),
        ),
      );
    }
    await session.close();
    expect(handle.calls, ['cancel', 'close']);
  });

  test('a stream whose subscription is cancelled before its end ends the '
      'session; one listened to its end does not', () async {
    final handle = _Handle();
    final session = newSession(handle, () => false);
    await session.generateContentStream([const InputData.text('a')]).toList();
    await session.runDecode();
    final subscription = session
        .generateContentStream([const InputData.text('b')])
        .listen((_) {});
    await subscription.cancel();
    expect(session.runDecode, throwsStateError);
  });

  test('a call that makes a session: OK with a NULL session is a failure, '
      'never a session at address 0', () {
    expect(sessionMadeResult('c', 0, 0x20, () => null).address, 0x20);
    final nullOk = sessionMadeResult('c', 0, 0, () => null);
    expect(nullOk.code, isNot(0));
    expect(nullOk.message, contains('returned OK with no session'));
    final failed = sessionMadeResult('c', 3, 0x20, () => 'bad');
    expect((failed.code, failed.address, failed.message), (3, 0, 'bad'));
  });

  test("a session stream's CANCELLED end: normal when its caller stopped it, "
      'a StateError when the engine closes, else a native error', () {
    final client = LiteRtLmFfiClient()..seedLiveSessionForTest(0x30);
    expect(
      client.sessionStreamFailureForTest(
        0x30,
        'CANCELLED.',
        shuttingDown: true,
      ),
      isA<StateError>(),
    );
    expect(
      client.sessionStreamFailureForTest(0x30, 'CANCELLED.'),
      isA<LiteRtLmNativeException>(),
    );
    expect(
      client.sessionStreamFailureForTest(0x30, 'Max number of tokens reached.'),
      isA<LiteRtLmNativeException>(),
    );
  });

  test('the native handle maps each input to its C type, and refuses media '
      'for an encoder the engine did not load', () {
    final input = Uint8List.fromList([1, 2]);
    expect(sessionText('hé').bytes, [104, 195, 169]);
    final none = NativeSessionHandle(
      LiteRtLmFfiClient(),
      0x10,
      vision: false,
      audio: false,
    );
    expect(
      () => none.runPrefill([InputData.image(input)]),
      throwsUnsupportedError,
    );
    expect(
      () => none.runPrefill([InputData.audio(input)]),
      throwsUnsupportedError,
    );
    expect(
      nativeSessionInputsForTest(
        NativeSessionHandle(
          LiteRtLmFfiClient(),
          0x10,
          vision: true,
          audio: true,
        ),
        [
          const InputData.text('a'),
          InputData.image(input),
          InputData.audio(input),
        ],
      ).map((i) => i.type),
      [0, 1, 3],
    );
  });

  test("Engine.createSession on a closed engine is a StateError", () async {
    final engine = engineForTest(LiteRtLmFfiClient());
    await engine.close();
    expect(engine.createSession, throwsStateError);
  });
}
