// Kotlin's Session API over a fake handle: what each call hands the handle,
// the checks before it, and the native handle's input mapping.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart'
    show LiteRtLmFfiClient, engineForTest;
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
      await session.generateContent([
        InputData.image(Uint8List(3)),
        const InputData.text('what?'),
      ]),
      'six',
    );
    expect(await session.generateContentStream([]).toList(), ['a', 'b']);
    session.cancelProcess();
    final clone = await session.clone();
    await clone.runDecode();
    expect(handle.calls, [
      'prefill(text:2 + 2?)',
      'decode',
      'generate(image:3,text:what?)',
      'stream()',
      'cancel',
    ]);
    expect(handle.clones.single.calls, ['decode']);
    expect(() => session.runPrefill([]), throwsArgumentError);
    await session.close();
    expect(handle.calls.last, 'close');
    expect(session.runDecode, throwsStateError);
    engineClosed = true;
    expect(clone.runDecode, throwsStateError);
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
