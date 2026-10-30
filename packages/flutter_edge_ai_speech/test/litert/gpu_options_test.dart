// The GPU options every speech-to-text graph is compiled with (#747; text-to-
// speech gets none), driven through fakes of the three LiteRT calls: no native
// library is loaded. The fakes read the payload the way LiteRT's GPU
// accelerator does (a NUL-terminated TOML string) and free it where LiteRT
// would. Also the compile-failure check both compile sites go through.
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/litert_bindings.dart'
    show
        LiteRtCompiledModel,
        LiteRtOpaqueOptions,
        LiteRtOptions,
        kLiteRtHwAcceleratorCpu,
        kLiteRtHwAcceleratorGpu,
        kLiteRtHwAcceleratorNpu;
import 'package:flutter_edge_ai_speech/src/litert/litert_graph.dart'
    show
        attachGpuOptions,
        checkCompiledModelStatus,
        compiledModelFailureMessage,
        takeCompiledModel,
        configureSpeechAcceleratorWith,
        liteRtGpuOptionsIdentifier,
        sttGpuOptionsToml;
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
  int? terminatedAt;
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
    final length = utf8.encode(payload!).length;
    terminatedAt = data.cast<Uint8>()[length] == 0 ? length : null;
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

/// Allocates through [malloc], as the payload must be, but fills every block
/// with 0xFF first (a missing NUL terminator then reads as garbage) and
/// records what [attachGpuOptions] frees itself.
class _RecordingAllocator implements Allocator {
  final allocated = <int>[];
  final freed = <int>[];

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final block = malloc.allocate<Uint8>(byteCount, alignment: alignment);
    block.asTypedList(byteCount).fillRange(0, byteCount, 0xFF);
    allocated.add(block.address);
    return block.cast();
  }

  @override
  void free(Pointer<NativeType> pointer) {
    freed.add(pointer.address);
    malloc.free(pointer);
  }
}

final LiteRtOptions _options = Pointer.fromAddress(0x0b7);

void main() {
  test('the speech-to-text GPU payload asks for fp32 and nothing else', () {
    expect(sttGpuOptionsToml, 'precision = 2\n');
    // Constant sharing aborts on a float32 EMBEDDING_LOOKUP (LiteRT-LM#3685).
    expect(sttGpuOptionsToml, isNot(contains('constant_tensors_sharing')));
  });

  test('attachGpuOptions hands LiteRT the gpu_options TOML and adds it', () {
    final fake = _FakeLiteRt();
    final allocator = _RecordingAllocator();
    attachGpuOptions(
      _options,
      'precision = 2\n',
      create: fake.create,
      add: fake.add,
      destroy: fake.destroy,
      allocator: allocator,
    );
    fake.release();

    // NUL-terminated: the accelerator reads it as a C string.
    expect(fake.terminatedAt, 'precision = 2\n'.length);
    // LiteRT owns it now; freeing it here would be a double free.
    expect(allocator.freed, isEmpty);

    expect(fake.calls, ['create', 'add']);
    expect(fake.identifier, liteRtGpuOptionsIdentifier);
    expect(fake.identifier, 'gpu_options');
    expect(fake.payload, 'precision = 2\n');
    expect(fake.destructor, malloc.nativeFree);
    expect(fake.addedTo, _options);
    expect(fake.added, fake.opaque);
    expect(fake.destroyed, isNull);
  });

  test('a failed create frees the payload, throws and never adds', () {
    final fake = _FakeLiteRt(createStatus: 1);
    final allocator = _RecordingAllocator();
    expect(
      () => attachGpuOptions(
        _options,
        'precision = 2\n',
        create: fake.create,
        add: fake.add,
        destroy: fake.destroy,
        allocator: allocator,
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
    // LiteRT never took it, so it is ours to free.
    expect(allocator.freed, [allocator.allocated.single]);
  });

  test('a failed add destroys the options it created, then throws', () {
    final fake = _FakeLiteRt(addStatus: 1);
    final allocator = _RecordingAllocator();
    expect(
      () => attachGpuOptions(
        _options,
        'precision = 2\n',
        create: fake.create,
        add: fake.add,
        destroy: fake.destroy,
        allocator: allocator,
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
    // Destroying the options ran the payload's destructor; a second free here
    // would be a double free.
    expect(allocator.freed, isEmpty);
  });

  group('configureSpeechAcceleratorWith', () {
    void configure(
      _FakeLiteRt fake,
      int accelerator, {
      bool fp32OnGpu = true,
    }) => configureSpeechAcceleratorWith(
      _options,
      accelerator,
      context: 'model.tflite',
      fp32OnGpu: fp32OnGpu,
      setAccelerators: fake.setAccelerators,
      create: fake.create,
      add: fake.add,
      destroy: fake.destroy,
    );

    test('speech-to-text on the GPU gets the fp32 options', () {
      final fake = _FakeLiteRt();
      configure(fake, kLiteRtHwAcceleratorGpu);
      fake.release();
      expect(fake.calls, [
        'setAccelerators($kLiteRtHwAcceleratorGpu)',
        'create',
        'add',
      ]);
      expect(fake.payload, sttGpuOptionsToml);
    });

    test('text-to-speech on the GPU keeps LiteRT defaults', () {
      final fake = _FakeLiteRt();
      configure(fake, kLiteRtHwAcceleratorGpu, fp32OnGpu: false);
      expect(fake.calls, ['setAccelerators($kLiteRtHwAcceleratorGpu)']);
    });

    for (final (name, accelerator) in [
      ('CPU', kLiteRtHwAcceleratorCpu),
      ('NPU', kLiteRtHwAcceleratorNpu),
    ]) {
      for (final fp32OnGpu in [true, false]) {
        test('the $name gets no GPU options (fp32OnGpu: $fp32OnGpu)', () {
          final fake = _FakeLiteRt();
          configure(fake, accelerator, fp32OnGpu: fp32OnGpu);
          expect(fake.calls, ['setAccelerators($accelerator)']);
        });
      }
    }

    test('a failed accelerator call throws before any GPU option', () {
      final fake = _FakeLiteRt();
      expect(
        () => configureSpeechAcceleratorWith(
          _options,
          kLiteRtHwAcceleratorGpu,
          context: 'model.tflite',
          fp32OnGpu: true,
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

  group('compiledModelFailureMessage', () {
    for (final (accelerator, name) in [
      (kLiteRtHwAcceleratorCpu, 'cpu'),
      (kLiteRtHwAcceleratorGpu, 'gpu'),
      (kLiteRtHwAcceleratorNpu, 'npu'),
    ]) {
      test('names the file, the $name and the status, and nothing more', () {
        expect(
          compiledModelFailureMessage(
            '/models/parakeet_ctc_0.6b_5s_i8.tflite',
            accelerator,
            3,
          ),
          'LiteRtCreateCompiledModel(/models/parakeet_ctc_0.6b_5s_i8.tflite) '
          'failed on the $name (status=3)',
        );
      });
    }
  });

  group('checkCompiledModelStatus', () {
    test('kLiteRtStatusOk (0) passes', () {
      checkCompiledModelStatus(
        0,
        path: '/models/a.tflite',
        accelerator: kLiteRtHwAcceleratorGpu,
      );
    });

    // 3: an int8 file on the GPU; 504: Matcha's G2P graph on Adreno (#747).
    for (final status in [1, 2, 3, 504, -1]) {
      test('status $status throws the failure message', () {
        expect(
          () => checkCompiledModelStatus(
            status,
            path: '/models/a.tflite',
            accelerator: kLiteRtHwAcceleratorGpu,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              compiledModelFailureMessage(
                '/models/a.tflite',
                kLiteRtHwAcceleratorGpu,
                status,
              ),
            ),
          ),
        );
      });
    }
  });

  group('takeCompiledModel', () {
    test('a compiled model is returned and its out pointer freed once', () {
      final out = calloc<LiteRtCompiledModel>();
      final compiled = Pointer<NativeType>.fromAddress(0xc0de).cast<Never>();
      out.value = Pointer.fromAddress(0xc0de);
      final freed = <int>[];
      final result = takeCompiledModel(
        out,
        0,
        path: '/models/a.tflite',
        accelerator: kLiteRtHwAcceleratorGpu,
        free: (p) {
          freed.add(p.address);
          calloc.free(p);
        },
      );
      expect(result.address, compiled.address);
      expect(freed, [out.address]);
    });

    test('a failed compile surfaces, with the pointer freed once', () {
      final out = calloc<LiteRtCompiledModel>();
      final freed = <int>[];
      expect(
        () => takeCompiledModel(
          out,
          3,
          path: '/models/a.tflite',
          accelerator: kLiteRtHwAcceleratorGpu,
          free: (p) {
            freed.add(p.address);
            calloc.free(p);
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            compiledModelFailureMessage(
              '/models/a.tflite',
              kLiteRtHwAcceleratorGpu,
              3,
            ),
          ),
        ),
      );
      expect(freed, [out.address]);
    });
  });
}
