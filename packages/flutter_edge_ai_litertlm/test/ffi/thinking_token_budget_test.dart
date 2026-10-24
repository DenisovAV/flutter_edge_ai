// applyThinkingTokenBudget over the real generated bindings, with each native
// function replaced by a Dart callback (NativeCallable): which calls a send
// makes, in which order, with which values. The budget must reach the send's
// optional args only when the send thinks and a budget is set, and the config
// must be deleted after the args have taken their copy.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _CreateN = Pointer<Void> Function();
typedef _DeleteN = Void Function(Pointer<Void>);
typedef _SetBoolN = Void Function(Pointer<Void>, Bool);
typedef _SetIntN = Void Function(Pointer<Void>, Int);
typedef _SetPtrN = Void Function(Pointer<Void>, Pointer<Void>);

class _FakeNative {
  _FakeNative({this.createReturnsNull = false});

  final bool createReturnsNull;
  final calls = <String>[];
  final config = calloc<Uint8>().cast<Void>();
  final _callables = <NativeCallable<Function>>[];

  late final LiteRtLmBindings bindings = LiteRtLmBindings.fromLookup(_lookup);

  Pointer<T> _lookup<T extends NativeType>(String name) {
    NativeCallable<Function> callable;
    switch (name) {
      case 'litert_lm_thinking_config_create':
        callable = NativeCallable<_CreateN>.isolateLocal(() {
          calls.add('create');
          return createReturnsNull ? nullptr : config;
        });
      case 'litert_lm_thinking_config_delete':
        callable = NativeCallable<_DeleteN>.isolateLocal((Pointer<Void> c) {
          calls.add('delete ${c == config}');
        });
      case 'litert_lm_thinking_config_set_enable_thinking':
        callable = NativeCallable<_SetBoolN>.isolateLocal((
          Pointer<Void> c,
          bool on,
        ) {
          calls.add('enable $on');
        });
      case 'litert_lm_thinking_config_set_thinking_token_budget':
        callable = NativeCallable<_SetIntN>.isolateLocal((
          Pointer<Void> c,
          int budget,
        ) {
          calls.add('budget $budget');
        });
      case 'litert_lm_conversation_optional_args_set_thinking_config':
        callable = NativeCallable<_SetPtrN>.isolateLocal((
          Pointer<Void> args,
          Pointer<Void> c,
        ) {
          calls.add('args ${c == config}');
        });
      default:
        throw ArgumentError('unexpected native call $name');
    }
    _callables.add(callable);
    return callable.nativeFunction.cast();
  }

  void close() {
    for (final c in _callables) {
      c.close();
    }
    calloc.free(config);
  }
}

void main() {
  final args = Pointer<LiteRtLmConversationOptionalArgs>.fromAddress(0x10);

  test('a thinking send with a budget: create, enable, budget, hand to the '
      'args, delete', () {
    final native = _FakeNative();
    addTearDown(native.close);
    applyThinkingTokenBudget(
      native.bindings,
      args,
      thinking: true,
      budget: 2048,
    );
    expect(native.calls, [
      'create',
      'enable true',
      'budget 2048',
      'args true',
      'delete true',
    ]);
  });

  test('no native call without a budget or without thinking', () {
    final native = _FakeNative();
    addTearDown(native.close);
    applyThinkingTokenBudget(
      native.bindings,
      args,
      thinking: true,
      budget: null,
    );
    applyThinkingTokenBudget(
      native.bindings,
      args,
      thinking: false,
      budget: 2048,
    );
    expect(native.calls, isEmpty);
  });

  test('a config native could not create fails the send', () {
    final native = _FakeNative(createReturnsNull: true);
    addTearDown(native.close);
    expect(
      () => applyThinkingTokenBudget(
        native.bindings,
        args,
        thinking: true,
        budget: 2048,
      ),
      throwsStateError,
    );
    expect(native.calls, ['create']);
  });
}
