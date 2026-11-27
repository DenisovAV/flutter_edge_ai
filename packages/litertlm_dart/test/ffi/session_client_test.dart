// The client's session calls over fake bindings: a clone that finishes while
// the engine shuts down is deleted with the engine's other sessions, and a
// stream that native ended with an error is not cancelled afterwards.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:litertlm_dart/litertlm_dart.dart' show LiteRtLmNativeException;
import 'package:litertlm_dart/bindings.dart'
    show LiteRtLmBindings, LiteRtLmEngine, LiteRtLmSession;
import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
import 'package:litertlm_dart/src/ffi/session_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('a clone that ends OK during shutdown is deleted by shutdown', () async {
    final calls = <String>[];
    final callables = <NativeCallable<Function>>[];
    final symbols = <String, Pointer<Void>>{};
    void add<T extends Function>(String name, NativeCallable<T> callable) {
      callables.add(callable);
      symbols[name] = callable.nativeFunction.cast();
    }

    add(
      'litert_lm_session_cancel_process',
      NativeCallable<
        UnsignedInt Function(Pointer<LiteRtLmSession>)
      >.isolateLocal((Pointer<LiteRtLmSession> s) {
        calls.add('cancel(${s.address})');
        return 0;
      }, exceptionalReturn: 1),
    );
    add(
      'litert_lm_session_delete',
      NativeCallable<Void Function(Pointer<LiteRtLmSession>)>.isolateLocal(
        (Pointer<LiteRtLmSession> s) => calls.add('delete(${s.address})'),
      ),
    );
    add(
      'litert_lm_engine_delete',
      NativeCallable<Void Function(Pointer<LiteRtLmEngine>)>.isolateLocal(
        (Pointer<LiteRtLmEngine> e) => calls.add('engine_delete'),
      ),
    );
    addTearDown(() {
      for (final c in callables) {
        c.close();
      }
    });

    final cloneEnds = Completer<SessionCallResult>();
    final cloneStarted = Completer<void>();
    final previous = sessionCloneOff;
    sessionCloneOff = ({required int sessionAddr}) {
      cloneStarted.complete();
      return cloneEnds.future;
    };
    addTearDown(() => sessionCloneOff = previous);

    final client = LiteRtLmFfiClient()
      ..streamForTest(
        createProxy: (_, _, _, _, _, _) => nullptr,
        freeString: (_) {},
        destroyProxy: (_) {},
      )
      ..bindingsForTest = LiteRtLmBindings.fromLookup(
        <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
      )
      ..seedLiveSessionForTest(0x30);

    final clone = client.sessionClone(0x30);
    final cloneOutcome = expectLater(clone, throwsStateError);
    await cloneStarted.future;
    final shutdown = client.shutdown();
    // The clone was made natively while shutdown waited for the call.
    cloneEnds.complete((code: 0, address: 0x40, text: null, message: null));
    await cloneOutcome;
    await shutdown;

    expect(calls, contains('delete(${0x40})'));
    expect(calls, contains('delete(${0x30})'));
    expect(
      calls.indexOf('delete(${0x40})'),
      lessThan(calls.indexOf('engine_delete')),
    );
  });

  test('a stream that native ended with an error is not cancelled by its '
      "consumer's cancel on that error", () async {
    final cancels = <int>[];
    final cancel =
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmSession>)
        >.isolateLocal((Pointer<LiteRtLmSession> s) {
          cancels.add(s.address);
          return 0;
        }, exceptionalReturn: 1);
    addTearDown(cancel.close);
    final previous = sessionStreamOff;
    sessionStreamOff =
        ({
          required int sessionAddr,
          required List<SessionInput> inputs,
          required int callbackAddr,
          required int callbackDataAddr,
        }) async {
          // Native prefills, then its decode sends the error chunk; the call
          // returns a moment later.
          Pointer<NativeFunction<StreamCallbackNative>>.fromAddress(
                callbackAddr,
              )
              .asFunction<
                void Function(Pointer<Void>, Pointer<Char>, int, Pointer<Char>)
              >()(
            Pointer.fromAddress(callbackDataAddr),
            nullptr,
            1,
            'Max number of tokens reached.'.toNativeUtf8().cast(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return (code: 0, address: 0, text: null, message: null);
        };
    addTearDown(() => sessionStreamOff = previous);

    final client = LiteRtLmFfiClient()
      ..streamForTest(
        createProxy: (callback, _, _, _, _, outProxyFn) {
          outProxyFn.value = callback;
          return Pointer.fromAddress(0x99);
        },
        freeString: (p) => malloc.free(p),
        destroyProxy: (_) {},
      )
      ..bindingsForTest = LiteRtLmBindings.fromLookup(
        <T extends NativeType>(String name) => switch (name) {
          'litert_lm_session_cancel_process' => cancel.nativeFunction.cast<T>(),
          _ => throw ArgumentError(name),
        },
      )
      ..seedLiveSessionForTest(0x30);

    await expectLater(() async {
      // `await for` cancels the subscription on the error.
      await for (final _ in client.sessionGenerateStream(0x30, [
        (type: 0, bytes: Uint8List.fromList([0x61])),
      ])) {}
    }(), throwsA(isA<LiteRtLmNativeException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cancels, isEmpty);
    expect(client.isSessionCancelledForTest(0x30), isFalse);
  });
}
