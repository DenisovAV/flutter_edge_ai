// applyThinkingTokenBudget over the real generated bindings, with each native
// function replaced by a Dart callback (NativeCallable): which calls a send
// makes, in which order, with which values. The budget must reach the send's
// optional args only when the send thinks and a budget is set, and the config
// must be deleted after the args have taken their copy.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_bundle_sampler.dart';
import 'package:flutter_edge_ai_litertlm/src/thinking_token_budget.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _CreateN = Pointer<Void> Function();
typedef _DeleteN = Void Function(Pointer<Void>);
typedef _SetBoolN = Void Function(Pointer<Void>, Bool);
typedef _SetIntN = Void Function(Pointer<Void>, Int);
typedef _SetPtrN = Void Function(Pointer<Void>, Pointer<Void>);

class _FakeNative {
  _FakeNative({this.createReturnsNull = false});

  final bool createReturnsNull;

  /// The optional args the send hands over; the config must reach these.
  static final sendArgs = Pointer<LiteRtLmConversationOptionalArgs>.fromAddress(
    0x10,
  );
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
          calls.add('args ${args == sendArgs.cast<Void>()} ${c == config}');
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
  final args = _FakeNative.sendArgs;

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
      'args true true',
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

  test('a budget LiteRT-LM can take passes, from 1 to the largest C int', () {
    for (final budget in [null, 1, 2048, maxThinkingTokenBudget]) {
      checkThinkingTokenBudget(budget);
    }
    for (final budget in [0, -1, maxThinkingTokenBudget + 1, 1 << 32]) {
      expect(
        () => checkThinkingTokenBudget(budget),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'thinkingTokenBudget',
          ),
        ),
        reason: '$budget',
      );
    }
  });

  test('the web notice is said once per isolate', () async {
    resetThinkingTokenBudgetNotice();
    addTearDown(resetThinkingTokenBudgetNotice);
    final printed = <String>[];
    await runZoned(
      () async {
        noticeThinkingTokenBudgetIgnoredOnWeb();
        noticeThinkingTokenBudgetIgnoredOnWeb();
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    expect(
      printed.where((l) => l.contains('thinkingTokenBudget')),
      hasLength(1),
    );
  });

  test('with logging off the web notice is not spent: raised later, the '
      'line still comes', () async {
    resetThinkingTokenBudgetNotice();
    addTearDown(resetThinkingTokenBudgetNotice);
    final level = edgeAiLogLevel;
    addTearDown(() => edgeAiLogLevel = level);
    final printed = <String>[];
    await runZoned(
      () async {
        edgeAiLogLevel = EdgeAiLogLevel.none;
        noticeThinkingTokenBudgetIgnoredOnWeb();
        edgeAiLogLevel = EdgeAiLogLevel.info;
        noticeThinkingTokenBudgetIgnoredOnWeb();
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    expect(
      printed.where((l) => l.contains('thinkingTokenBudget')),
      hasLength(1),
    );
  });

  group('a budget on a bundle that declares no channel', () {
    const path = '/models/old-reasoning.litertlm';

    test('is warned about, naming the budget and the file', () {
      expect(
        thinkingBudgetChannelWarning(
          512,
          const BundleSamplerRead(SamplingParams(), declaresChannel: false),
          path,
        ),
        allOf(
          contains('WARNING'),
          contains('thinkingTokenBudget: 512'),
          contains('old-reasoning.litertlm'),
          isNot(contains('/models/')),
        ),
      );
    });

    test('is silent with a channel, with no budget, or with no read', () {
      expect(
        thinkingBudgetChannelWarning(
          512,
          const BundleSamplerRead(SamplingParams(), declaresChannel: true),
          path,
        ),
        isNull,
      );
      expect(
        thinkingBudgetChannelWarning(
          null,
          const BundleSamplerRead(SamplingParams(), declaresChannel: false),
          path,
        ),
        isNull,
      );
      // A failed read prints its own warning; this one would guess.
      expect(
        thinkingBudgetChannelWarning(
          512,
          const BundleSamplerRead.failed('FormatException: truncated'),
          path,
        ),
        isNull,
      );
    });
  });

  test('the client keeps the budget initialize was given', () async {
    final client = LiteRtLmFfiClient();
    // No engine can load from here; the budget is taken before the load.
    await expectLater(
      client.initialize(
        modelPath: '/nonexistent/model.litertlm',
        backend: 'cpu',
        thinkingTokenBudget: 7,
      ),
      throwsA(anything),
    );
    expect(client.thinkingTokenBudget, 7);
  });

  test('the release gate lists every C function a budget calls', () {
    final client = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    final apply = client.substring(
      client.indexOf('void applyThinkingTokenBudget('),
      client.indexOf('/// Callback typedef'),
    );
    final called = {
      for (final m in RegExp(r'b\.(litert_lm_[a-z_]+)\(').allMatches(apply))
        m.group(1)!,
    };
    final gate = File(
      'native/litert_lm/check_embedding_exports.py',
    ).readAsStringSync();
    final listed = RegExp(
      r'THINKING_BUDGET_SYMBOLS = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(gate)!.group(1)!;
    expect(called, hasLength(5));
    expect({
      for (final m in RegExp(r'"(litert_lm_[a-z_]+)"').allMatches(listed))
        m.group(1)!,
    }, called);
  });
}
