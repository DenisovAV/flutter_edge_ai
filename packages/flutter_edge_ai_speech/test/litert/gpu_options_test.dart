// The GPU options every speech graph is compiled with (#747), driven through
// fakes of the three LiteRT calls: no native library is loaded. The fakes
// read the payload the way LiteRT's GPU accelerator does (a NUL-terminated
// TOML string) and free it where LiteRT would.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/litert_bindings.dart'
    show
        LiteRtOpaqueOptions,
        LiteRtOptions,
        kLiteRtHwAcceleratorCpu,
        kLiteRtHwAcceleratorGpu,
        kLiteRtHwAcceleratorNpu;
import 'package:flutter_edge_ai_speech/src/litert/litert_graph.dart'
    show
        attachGpuOptions,
        configureSpeechAcceleratorWith,
        liteRtGpuOptionsIdentifier,
        speechGpuOptionsToml;
import 'package:flutter_test/flutter_test.dart';

/// Records what [attachGpuOptions] hands to LiteRT and owns the payload the
/// way LiteRT does once a call succeeds.
class _FakeLiteRt {
  _FakeLiteRt({this.createStatus = 0, this.addStatus = 0});

  final int createStatus;
  final int addStatus;

  final calls = <String>[];
  String? identifier;
  String? payload;
  Pointer<NativeFinalizerFunction>? destructor;
  LiteRtOptions? addedTo;
  LiteRtOpaqueOptions? added;
  LiteRtOpaqueOptions? destroyed;
  Pointer<Void>? _ownedPayload;

  final LiteRtOpaqueOptions opaque = Pointer.fromAddress(0x5eed);

  int create(
    Pointer<Utf8> id,
    Pointer<Void> data,
    Pointer<NativeFinalizerFunction> free,
    Pointer<LiteRtOpaqueOptions> out,
  ) {
    calls.add('create');
    identifier = id.toDartString();
    payload = data.cast<Utf8>().toDartString();
    destructor = free;
    if (createStatus != 0) return createStatus;
    _ownedPayload = data;
    out.value = opaque;
    return 0;
  }

  int add(LiteRtOptions options, LiteRtOpaqueOptions opaque) {
    calls.add('add');
    addedTo = options;
    added = opaque;
    return addStatus;
  }

  void destroy(LiteRtOpaqueOptions opaque) {
    calls.add('destroy');
    destroyed = opaque;
    release();
  }

  int setAccelerators(LiteRtOptions options, int accelerator) {
    calls.add('setAccelerators($accelerator)');
    return 0;
  }

  /// Frees the payload LiteRT took ownership of, as its destructor would.
  void release() {
    final owned = _ownedPayload;
    if (owned != null) malloc.free(owned);
    _ownedPayload = null;
  }
}

final LiteRtOptions _options = Pointer.fromAddress(0x0b7);

void main() {
  test('the speech GPU payload asks for fp32 and nothing else', () {
    expect(speechGpuOptionsToml, 'precision = 2\n');
    // Constant sharing aborts on a float32 EMBEDDING_LOOKUP (LiteRT-LM#3685).
    expect(speechGpuOptionsToml, isNot(contains('constant_tensors_sharing')));
  });

  test('attachGpuOptions hands LiteRT the gpu_options TOML and adds it', () {
    final fake = _FakeLiteRt();
    attachGpuOptions(
      _options,
      'precision = 2\n',
      create: fake.create,
      add: fake.add,
      destroy: fake.destroy,
    );
    fake.release();

    expect(fake.calls, ['create', 'add']);
    expect(fake.identifier, liteRtGpuOptionsIdentifier);
    expect(fake.identifier, 'gpu_options');
    expect(fake.payload, 'precision = 2\n');
    expect(fake.destructor, malloc.nativeFree);
    expect(fake.addedTo, _options);
    expect(fake.added, fake.opaque);
    expect(fake.destroyed, isNull);
  });

  test('a failed create throws and never adds', () {
    final fake = _FakeLiteRt(createStatus: 1);
    expect(
      () => attachGpuOptions(
        _options,
        'precision = 2\n',
        create: fake.create,
        add: fake.add,
        destroy: fake.destroy,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('LiteRtCreateOpaqueOptions(gpu_options)'),
        ),
      ),
    );
    expect(fake.calls, ['create']);
  });

  test('a failed add destroys the options it created, then throws', () {
    final fake = _FakeLiteRt(addStatus: 1);
    expect(
      () => attachGpuOptions(
        _options,
        'precision = 2\n',
        create: fake.create,
        add: fake.add,
        destroy: fake.destroy,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('LiteRtAddOpaqueOptions(gpu_options)'),
        ),
      ),
    );
    expect(fake.calls, ['create', 'add', 'destroy']);
    expect(fake.destroyed, fake.opaque);
  });

  group('configureSpeechAcceleratorWith', () {
    void configure(_FakeLiteRt fake, int accelerator) =>
        configureSpeechAcceleratorWith(
          _options,
          accelerator,
          context: 'model.tflite',
          setAccelerators: fake.setAccelerators,
          create: fake.create,
          add: fake.add,
          destroy: fake.destroy,
        );

    test('the GPU gets the speech GPU options', () {
      final fake = _FakeLiteRt();
      configure(fake, kLiteRtHwAcceleratorGpu);
      fake.release();
      expect(fake.calls, [
        'setAccelerators($kLiteRtHwAcceleratorGpu)',
        'create',
        'add',
      ]);
      expect(fake.payload, speechGpuOptionsToml);
    });

    for (final (name, accelerator) in [
      ('CPU', kLiteRtHwAcceleratorCpu),
      ('NPU', kLiteRtHwAcceleratorNpu),
    ]) {
      test('the $name gets no GPU options', () {
        final fake = _FakeLiteRt();
        configure(fake, accelerator);
        expect(fake.calls, ['setAccelerators($accelerator)']);
      });
    }

    test('a failed accelerator call throws before any GPU option', () {
      final fake = _FakeLiteRt();
      expect(
        () => configureSpeechAcceleratorWith(
          _options,
          kLiteRtHwAcceleratorGpu,
          context: 'model.tflite',
          setAccelerators: (_, _) => 1,
          create: fake.create,
          add: fake.add,
          destroy: fake.destroy,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('LiteRtSetOptionsHardwareAccelerators(model.tflite)'),
          ),
        ),
      );
      expect(fake.calls, isEmpty);
    });
  });
}
