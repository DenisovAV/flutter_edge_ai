import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmEngineCreateException, LiteRtLmLogLevel;
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `createEngineWith` is the body `initialize` runs on the engine's isolate:
/// the settings, every setter, the create and LiteRT-LM's last error. These
/// tests run it on fake native functions that record each call, so they see
/// the order and the values a real library would get.

typedef _CreateSettingsN =
    Pointer<Void> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef _SettingsN = Void Function(Pointer<Void>);
typedef _SettingsIntN = Void Function(Pointer<Void>, Int);
typedef _SettingsBoolN = Void Function(Pointer<Void>, Bool);
typedef _SettingsStringN = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _CreateEngineN = Pointer<Void> Function(Pointer<Void>);
typedef _IntN = Void Function(Int);
typedef _VoidN = Void Function();
typedef _CodeN = Int32 Function();
typedef _MessageN = Pointer<Utf8> Function();

class _FakeLiteRtLm {
  _FakeLiteRtLm({
    this.settingsNull = false,
    this.engineNull = false,
    this.lastError = true,
    this.errorCode = 0,
    String? errorMessage,
    this.missing = const {},
  }) : _message = errorMessage == null ? nullptr : errorMessage.toNativeUtf8();

  final bool settingsNull;
  final bool engineNull;

  /// Whether the library exports the last-error functions.
  final bool lastError;
  final int errorCode;
  final Pointer<Utf8> _message;

  /// Symbols whose lookup throws, as a library without the export does.
  final Set<String> missing;

  static final engine = Pointer<Void>.fromAddress(0xE9E);
  final settings = calloc<Uint8>().cast<Void>();
  final calls = <String>[];
  final _callables = <NativeCallable<Function>>[];

  late final LiteRtLmBindings bindings = LiteRtLmBindings.fromLookup(lookup);

  bool provides(String symbol) => lastError || !symbol.contains('last_error');

  String _settings(Pointer<Void> s) => s == settings ? '' : ' (foreign)';

  static String _string(Pointer<Utf8> p) =>
      p == nullptr ? 'null' : p.toDartString();

  Pointer<T> lookup<T extends NativeType>(String name) {
    if (missing.contains(name)) {
      throw ArgumentError('no $name in this library');
    }
    final short = name.replaceFirst('litert_lm_', '');
    NativeCallable<Function> callable;
    switch (short) {
      case 'set_min_log_level':
        callable = NativeCallable<_IntN>.isolateLocal((int level) {
          calls.add('log_level $level');
        });
      case 'engine_settings_create':
        callable = NativeCallable<_CreateSettingsN>.isolateLocal((
          Pointer<Utf8> model,
          Pointer<Utf8> backend,
          Pointer<Utf8> vision,
          Pointer<Utf8> audio,
        ) {
          calls.add(
            'settings_create ${_string(model)} ${_string(backend)} '
            'vision=${_string(vision)} audio=${_string(audio)}',
          );
          return settingsNull ? nullptr : settings;
        });
      case 'engine_settings_enable_benchmark' || 'engine_settings_delete':
        callable = NativeCallable<_SettingsN>.isolateLocal((Pointer<Void> s) {
          calls.add(
            '${short.replaceFirst('engine_settings_', '')}'
            '${_settings(s)}',
          );
        });
      case 'engine_settings_set_max_num_tokens' ||
          'engine_settings_set_max_num_images' ||
          'engine_settings_set_activation_data_type' ||
          'engine_settings_set_kernel_batch_size':
        callable = NativeCallable<_SettingsIntN>.isolateLocal((
          Pointer<Void> s,
          int value,
        ) {
          calls.add(
            '${short.replaceFirst('engine_settings_set_', '')} $value'
            '${_settings(s)}',
          );
        });
      case 'engine_settings_set_enable_speculative_decoding' ||
          'engine_settings_set_use_hw_masking_for_npu':
        callable = NativeCallable<_SettingsBoolN>.isolateLocal((
          Pointer<Void> s,
          bool value,
        ) {
          calls.add(
            '${short.replaceFirst('engine_settings_set_', '')} $value'
            '${_settings(s)}',
          );
        });
      case 'engine_settings_set_cache_dir' ||
          'engine_settings_set_litert_dispatch_lib_dir':
        callable = NativeCallable<_SettingsStringN>.isolateLocal((
          Pointer<Void> s,
          Pointer<Utf8> value,
        ) {
          calls.add(
            '${short.replaceFirst('engine_settings_set_', '')} '
            '${_string(value)}${_settings(s)}',
          );
        });
      case 'engine_create':
        callable = NativeCallable<_CreateEngineN>.isolateLocal((
          Pointer<Void> s,
        ) {
          calls.add('engine_create${_settings(s)}');
          return engineNull ? nullptr : engine;
        });
      case 'clear_last_error':
        callable = NativeCallable<_VoidN>.isolateLocal(() {
          calls.add('clear_last_error');
        });
      case 'get_last_error_code':
        callable = NativeCallable<_CodeN>.isolateLocal(() {
          calls.add('get_last_error_code');
          return errorCode;
        }, exceptionalReturn: 0);
      case 'get_last_error_message':
        callable = NativeCallable<_MessageN>.isolateLocal(() {
          calls.add('get_last_error_message');
          return _message;
        });
      default:
        throw ArgumentError('unexpected native call $name');
    }
    _callables.add(callable);
    return callable.nativeFunction.cast();
  }

  /// Runs [body] the way withSigprofBlocked does, recording where it starts
  /// and ends.
  T blockingSigprof<T>(T Function() body) {
    calls.add('sigprof blocked');
    try {
      return body();
    } finally {
      calls.add('sigprof restored');
    }
  }

  EngineCreateResult create(EngineCreateRequest request) => createEngineWith(
    request,
    bindings,
    provides: provides,
    lookup: lookup,
    blockingSigprof: blockingSigprof,
  );

  void close() {
    for (final c in _callables) {
      c.close();
    }
    calloc.free(settings);
    if (_message != nullptr) malloc.free(_message);
  }
}

const _full = EngineCreateRequest(
  modelPath: '/models/gemma.litertlm',
  backend: 'npu',
  maxTokens: 4096,
  logLevel: EdgeAiLogLevel.none,
  visionBackend: 'cpu',
  audioBackend: 'gpu',
  cacheDir: '/cache',
  maxNumImages: 2,
  enableSpeculativeDecoding: false,
  activationDataType: 0,
  nativeLogLevel: LiteRtLmLogLevel.warning,
  dispatchLibDir: '/vendor/dispatch',
  disableHwMaskingForNpu: true,
  kernelBatchSize: 2,
  blockSigprof: true,
);

const _empty = EngineCreateRequest(
  modelPath: '/models/gemma.litertlm',
  backend: 'cpu',
  maxTokens: 1024,
  logLevel: EdgeAiLogLevel.none,
);

void main() {
  late _FakeLiteRtLm fake;

  tearDown(() => fake.close());

  test('a full request: every setter once, with its value, before the '
      'create, which runs with SIGPROF blocked', () {
    fake = _FakeLiteRtLm();

    final result = fake.create(_full);

    expect(fake.calls, [
      'log_level ${LiteRtLmLogLevel.warning.nativeValue}',
      'clear_last_error',
      'settings_create /models/gemma.litertlm npu vision=cpu audio=gpu',
      'max_num_tokens 4096',
      'enable_benchmark',
      'cache_dir /cache',
      'max_num_images 2',
      'enable_speculative_decoding false',
      'activation_data_type 0',
      'use_hw_masking_for_npu false',
      'litert_dispatch_lib_dir /vendor/dispatch',
      'kernel_batch_size 2',
      'clear_last_error',
      'sigprof blocked',
      'engine_create',
      'sigprof restored',
      'delete',
    ]);
    expect(result.address, _FakeLiteRtLm.engine.address);
    expect(result.code, 0);
    expect(result.message, isNull);
  });

  test('an empty request calls no optional setter and does not block '
      'SIGPROF', () {
    fake = _FakeLiteRtLm();

    fake.create(_empty);

    expect(fake.calls, [
      'clear_last_error',
      'settings_create /models/gemma.litertlm cpu vision=null audio=null',
      'max_num_tokens 1024',
      'enable_benchmark',
      'clear_last_error',
      'engine_create',
      'delete',
    ]);
  });

  test('a NULL engine reads the last error right after the create, then '
      'deletes the settings', () {
    fake = _FakeLiteRtLm(
      engineNull: true,
      errorCode: 13,
      errorMessage: 'Main backend constraint mismatch',
    );

    final result = fake.create(_empty);

    final create = fake.calls.indexOf('engine_create');
    expect(fake.calls.sublist(create), [
      'engine_create',
      'get_last_error_code',
      'get_last_error_message',
      'delete',
    ]);
    expect(result.address, 0);
    expect(result.code, 13);
    expect(result.message, 'Main backend constraint mismatch');
    expect(result.banks, isNull);
  });

  test('a library without the last error: no clear, no read, code 0', () {
    fake = _FakeLiteRtLm(engineNull: true, lastError: false);

    final result = fake.create(_empty);

    expect(fake.calls.where((c) => c.contains('last_error')), isEmpty);
    expect(result.address, 0);
    expect(result.code, 0);
    expect(result.message, isNull);
  });

  test('a NULL settings create throws with LiteRT-LM\'s reason, and has '
      'nothing to delete', () {
    fake = _FakeLiteRtLm(
      settingsNull: true,
      errorCode: 3,
      errorMessage: 'Unsupported backend: gpu2',
    );

    expect(
      () => fake.create(_empty),
      throwsA(
        isA<LiteRtLmEngineCreateException>()
            .having((e) => e.nativeCode, 'nativeCode', 3)
            .having(
              (e) => e.nativeMessage,
              'nativeMessage',
              'Unsupported backend: gpu2',
            )
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains('Unsupported backend: gpu2'),
                contains('Model: /models/gemma.litertlm'),
              ),
            ),
      ),
    );
    expect(fake.calls, [
      'clear_last_error',
      'settings_create /models/gemma.litertlm cpu vision=null audio=null',
      'get_last_error_code',
      'get_last_error_message',
    ]);
  });

  for (final lastError in [true, false]) {
    test('a NULL settings create with no reason (last error '
        '${lastError ? 'code 0' : 'not exported'}) throws without one', () {
      fake = _FakeLiteRtLm(settingsNull: true, lastError: lastError);

      expect(
        () => fake.create(_empty),
        throwsA(
          isA<LiteRtLmEngineCreateException>()
              .having((e) => e.nativeCode, 'nativeCode', isNull)
              .having((e) => e.nativeMessage, 'nativeMessage', isNull)
              .having(
                (e) => e.message,
                'message',
                'Failed to create engine settings on cpu. '
                    'Model: /models/gemma.litertlm',
              ),
        ),
      );
    });
  }

  test('a setter the library lacks throws, and the settings are deleted '
      'exactly once', () {
    fake = _FakeLiteRtLm(missing: {'litert_lm_engine_settings_set_cache_dir'});

    expect(() => fake.create(_full), throwsArgumentError);
    expect(fake.calls.where((c) => c == 'delete'), hasLength(1));
    expect(fake.calls, isNot(contains('engine_create')));
  });
}
