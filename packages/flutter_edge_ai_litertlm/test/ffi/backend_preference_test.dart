import 'dart:async';
import 'dart:ffi' show Abi;

import 'package:flutter_edge_ai_litertlm/src/ffi/backend_preference.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs [body] and returns everything it `print`ed, with `gemmaLog` muted — so
/// a line that shows up here reached `print` itself, the one channel a release
/// build keeps.
Future<List<String>> _printedWithGemmaLogMuted(
  Future<void> Function() body,
) async {
  final printed = <String>[];
  final level = edgeAiLogLevel;
  edgeAiLogLevel = EdgeAiLogLevel.none;
  try {
    await runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
  } finally {
    edgeAiLogLevel = level;
  }
  return printed;
}

void main() {
  group('ffiBackendFallbackOrder', () {
    test('tries NPU, then GPU, then CPU where an NPU dispatch stack ships', () {
      expect(
        ffiBackendFallbackOrder(PreferredBackend.npu, npuAvailable: true),
        const [
          PreferredBackend.npu,
          PreferredBackend.gpu,
          PreferredBackend.cpu,
        ],
      );
    });

    test('does not offer NPU where no dispatch stack ships', () {
      // The native runtime accepts `backend: "npu"` on a host that cannot
      // honour it and does not fail, and initializeFfiRuntime reports the first
      // candidate whose init did not throw — so offering npu here is what made
      // a Mac report `activeBackend == npu`. Measured on macOS with Gemma 4
      // E2B before this gate existed.
      expect(
        ffiBackendFallbackOrder(PreferredBackend.npu, npuAvailable: false),
        const [PreferredBackend.gpu, PreferredBackend.cpu],
        reason:
            'a backend we cannot run must not be reported as the one we ran',
      );
    });
  });

  group('npuUnreachable', () {
    // The rule over fake probes rather than the platform host, because
    // `Platform.operatingSystem` has no override seam — asserting it on a
    // macOS runner compares no-NPU to no-NPU and would pass for an
    // implementation that disabled the NPU everywhere.
    test('Qualcomm asks only its own probe of its own OS', () {
      for (final (os, probe) in [
        ('android', 'androidFastRpc'),
        ('linux', 'linuxQualcommNpu'),
      ]) {
        final ok = _FakeProbes();
        expect(npuUnreachable(NpuVendor.qualcomm, os, ok), isNull);
        expect(ok.asked, [probe], reason: os);
      }
    });

    test('Intel on Windows asks no probe at all', () {
      final probes = _FakeProbes(error: 'should not be asked');
      expect(npuUnreachable(NpuVendor.intel, 'windows', probes), isNull);
      expect(probes.asked, isEmpty);
    });

    test('an operating system a vendor has no probe for is a programming '
        'error, never another platform\'s answer', () {
      for (final (vendor, os) in [
        (NpuVendor.qualcomm, 'windows'),
        (NpuVendor.qualcomm, 'macos'),
        (NpuVendor.intel, 'android'),
        (NpuVendor.intel, 'linux'),
      ]) {
        final probes = _FakeProbes();
        expect(
          () => npuUnreachable(vendor, os, probes),
          throwsStateError,
          reason: '$vendor on $os',
        );
        expect(probes.asked, isEmpty, reason: '$vendor on $os');
      }
    });

    test('the reason is worded per platform, with the probe error kept', () {
      final android = npuUnreachable(
        NpuVendor.qualcomm,
        'android',
        _FakeProbes(error: 'dlopen failed: library "libcdsprpc.so" not found'),
      );
      expect(
        android,
        'this device has no Qualcomm FastRPC (libcdsprpc.so did not open: '
        'dlopen failed: library "libcdsprpc.so" not found), so the bundled NPU '
        'stack cannot run here',
      );
      expect(
        android,
        isNot(contains('ships')),
        reason: 'the stack does ship on Android; the device lacks FastRPC',
      );

      final linux = npuUnreachable(
        NpuVendor.qualcomm,
        'linux',
        _FakeProbes(
          error:
              '/dev/dma_heap/system is not accessible to this user. '
              'Add the user to group fastrpc',
        ),
      );
      expect(linux, contains('group fastrpc'), reason: 'the fix is named');
      expect(
        linux,
        startsWith('the bundled Qualcomm NPU stack cannot run here'),
      );
    });

    test('a host no vendor runs on is named by its ABI', () {
      expect(
        npuNoVendorReason('linux_x64'),
        'no NPU dispatch stack ships for '
        'linux_x64',
      );
      expect(npuNoVendorReason('macos_arm64'), isNot(contains('FastRPC')));
    });

    test('the platform probes have not run on a host no vendor runs on', () {
      // `chooseNpuVendor` never asks a vendor of another ABI; the probes are
      // dlopens and device files, which do not belong on such a host.
      if (NpuVendor.forAbi('${Abi.current()}').isNotEmpty) return;
      expect(fastRpcProbed, isFalse);
      expect(linuxNpuProbed, isFalse);
    });
  });

  group('ffiBackendFallbackOrder (continued)', () {
    test('tries GPU, then CPU for a GPU preference', () {
      expect(
        ffiBackendFallbackOrder(PreferredBackend.gpu, npuAvailable: false),
        const [PreferredBackend.gpu, PreferredBackend.cpu],
      );
    });

    test('tries GPU, then CPU when no preference is provided', () {
      expect(ffiBackendFallbackOrder(null, npuAvailable: false), const [
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      ]);
    });

    test('tries only CPU for a CPU preference', () {
      expect(
        ffiBackendFallbackOrder(PreferredBackend.cpu, npuAvailable: false),
        const [PreferredBackend.cpu],
      );
    });
  });

  group('ffiBackendWireName', () {
    test('serializes backend preferences for LiteRT-LM', () {
      expect(ffiBackendWireName(PreferredBackend.npu), 'npu');
      expect(ffiBackendWireName(PreferredBackend.gpu), 'gpu');
      expect(ffiBackendWireName(PreferredBackend.cpu), 'cpu');
    });
  });

  group('initializeFfiRuntime', () {
    test(
      'returns the first successfully initialized fallback backend',
      () async {
        final clients = <_FakeClient>[];

        final runtime = await initializeFfiRuntime<_FakeClient>(
          preferredBackend: PreferredBackend.gpu,
          backends: ffiBackendFallbackOrder(
            PreferredBackend.gpu,
            npuAvailable: false,
          ),
          logTag: '[Test]',
          createClient: () {
            final client = _FakeClient();
            clients.add(client);
            return client;
          },
          initializeClient: (client, backend) async {
            client.backend = backend;
            if (backend == PreferredBackend.gpu) {
              throw Exception('gpu unavailable');
            }
          },
          shutdownClient: (client) => client.shutdown(),
        );

        expect(runtime.activeBackend, PreferredBackend.cpu);
        expect(runtime.client, same(clients[1]));
        expect(clients[0].isShutdown, isTrue);
        expect(clients[1].isShutdown, isFalse);
      },
    );

    test('throws an inspectable exception with all backend attempts', () async {
      final clients = <_FakeClient>[];

      await expectLater(
        initializeFfiRuntime<_FakeClient>(
          preferredBackend: PreferredBackend.npu,
          // Pinned rather than host-dependent: this case is about all THREE
          // attempts being reported, which needs npu to be on offer.
          backends: ffiBackendFallbackOrder(
            PreferredBackend.npu,
            npuAvailable: true,
          ),
          logTag: '[Test]',
          createClient: () {
            final client = _FakeClient();
            clients.add(client);
            return client;
          },
          initializeClient: (client, backend) async {
            client.backend = backend;
            throw Exception('${ffiBackendWireName(backend)} failed');
          },
          shutdownClient: (client) => client.shutdown(),
        ),
        throwsA(
          isA<BackendInitException>()
              .having(
                (exception) =>
                    exception.attempts.map((attempt) => attempt.backend),
                'attempted backends',
                [
                  PreferredBackend.npu,
                  PreferredBackend.gpu,
                  PreferredBackend.cpu,
                ],
              )
              .having(
                (exception) => exception.lastAttempt.backend,
                'last attempt',
                PreferredBackend.cpu,
              ),
        ),
      );

      expect(clients, hasLength(3));
      expect(clients.every((client) => client.isShutdown), isTrue);
    });

    test(
      'an npu request that cannot be honoured is printed, not only logged',
      () async {
        final printed = await _printedWithGemmaLogMuted(() async {
          await initializeFfiRuntime<_FakeClient>(
            preferredBackend: PreferredBackend.npu,
            backends: ffiBackendFallbackOrder(
              PreferredBackend.npu,
              npuAvailable: false,
            ),
            logTag: '[Test]',
            createClient: _FakeClient.new,
            initializeClient: (_, _) async {},
            shutdownClient: (client) => client.shutdown(),
          );
        });
        expect(printed, hasLength(1));
        expect(printed.single, contains('npu was requested'));
        expect(printed.single, contains('gpu -> cpu'));
      },
    );

    test('a requested backend the model file rules out is printed with the '
        "file's reason, not the host's", () async {
      // Gemma 3n declares cpu,gpu for its text model: asked for the NPU, the
      // load plan leaves it out because of the file, on a device that may
      // well have one.
      const declared =
          'model.litertlm declares that its text model runs on cpu, gpu '
          '(backend_constraint)';
      final printed = await _printedWithGemmaLogMuted(() async {
        await initializeFfiRuntime<_FakeClient>(
          preferredBackend: PreferredBackend.npu,
          logTag: '[Test]',
          createClient: _FakeClient.new,
          initializeClient: (_, _) async {},
          shutdownClient: (client) => client.shutdown(),
          backends: const [PreferredBackend.gpu, PreferredBackend.cpu],
          droppedBecause: const {PreferredBackend.npu: declared},
        );
      });
      expect(printed, [
        '[flutter_edge_ai] WARNING: [Test] npu was requested, but $declared — '
            'trying gpu -> cpu instead. InferenceModel.activeBackend names '
            'what actually ran.',
      ]);
    });

    test('a requested GPU the model file rules out is printed, not dropped '
        'silently', () async {
      final printed = await _printedWithGemmaLogMuted(() async {
        await initializeFfiRuntime<_FakeClient>(
          preferredBackend: PreferredBackend.gpu,
          logTag: '[Test]',
          createClient: _FakeClient.new,
          initializeClient: (_, _) async {},
          shutdownClient: (client) => client.shutdown(),
          backends: const [PreferredBackend.cpu],
          droppedBecause: const {
            PreferredBackend.gpu:
                'model.litertlm declares that its text model runs on cpu '
                '(backend_constraint)',
          },
        );
      });
      expect(printed, hasLength(1));
      expect(
        printed.single,
        contains(
          'gpu was requested, but model.litertlm declares that its text model '
          'runs on cpu (backend_constraint) — trying cpu instead',
        ),
      );
    });

    test('a failed backend is printed, and the last one does not promise a '
        'next', () async {
      final printed = await _printedWithGemmaLogMuted(() async {
        await expectLater(
          initializeFfiRuntime<_FakeClient>(
            preferredBackend: PreferredBackend.gpu,
            backends: ffiBackendFallbackOrder(
              PreferredBackend.gpu,
              npuAvailable: false,
            ),
            logTag: '[Test]',
            createClient: _FakeClient.new,
            initializeClient: (_, backend) async =>
                throw Exception('${ffiBackendWireName(backend)} failed'),
            shutdownClient: (client) => client.shutdown(),
          ),
          throwsA(isA<BackendInitException>()),
        );
      });
      expect(printed, hasLength(2));
      expect(printed.first, contains('gpu backend failed, trying the next'));
      expect(
        printed.last,
        contains('cpu backend failed, no candidates are left'),
      );
    });

    test('requires at least one failed backend attempt', () {
      expect(
        () => BackendInitException(attempts: const []),
        throwsArgumentError,
      );
    });

    test(
      'does not catch programming errors as backend fallback failures',
      () async {
        final error = AssertionError('bug');
        late _FakeClient client;

        await expectLater(
          initializeFfiRuntime<_FakeClient>(
            preferredBackend: PreferredBackend.cpu,
            backends: ffiBackendFallbackOrder(
              PreferredBackend.cpu,
              npuAvailable: false,
            ),
            logTag: '[Test]',
            createClient: () => client = _FakeClient(),
            initializeClient: (_, __) async => throw error,
            shutdownClient: (client) => client.shutdown(),
          ),
          throwsA(same(error)),
        );

        expect(client.isShutdown, isFalse);
      },
    );
  });

  group('encoderBackendWireName (vision + audio encoders)', () {
    // The LLM engine passes the load plan's choice from the bundle; null
    // reaches here only for a file the plan could not read. The VISION encoder
    // graph carries STABLEHLO_COMPOSITE ops the Metal / WebGPU LiteRT delegates
    // can't prepare (hard-fails at conversation_create, no fallback —
    // LiteRT-LM#2461), so CPU is the op-safe default there, and the published
    // Gemma 4 and Gemma 3n audio encoders declare cpu.
    test('defaults to cpu when no encoder backend is set (null)', () {
      expect(encoderBackendWireName(null), 'cpu');
    });

    test('passes an explicit override through unchanged', () {
      expect(encoderBackendWireName(PreferredBackend.gpu), 'gpu');
      expect(encoderBackendWireName(PreferredBackend.npu), 'npu');
      expect(encoderBackendWireName(PreferredBackend.cpu), 'cpu');
    });
  });

  group('activationDataTypeWireValue', () {
    // The numbers are LiteRT-LM's ActivationDataType order in
    // executor_settings_base.h, which the C setter casts the int to. A wrong
    // number is silent: F16 for F32 builds an engine that still writes the
    // wrong digits the setting was meant to fix.
    test('null leaves the engine setting untouched', () {
      expect(activationDataTypeWireValue(null), isNull);
    });

    test('matches the C API numbering', () {
      expect(activationDataTypeWireValue(ActivationDataType.float32), 0);
      expect(activationDataTypeWireValue(ActivationDataType.float16), 1);
    });

    test('offers only the two float types', () {
      // I16 (2) and I8 (3) are in LiteRT-LM's enum and deliberately not in
      // ours: at the pinned version they are not half precision the way F16 is,
      // and an unsupported type fails engine init, which reads as a quiet fall
      // back to CPU. Adding one back means adding a number here too.
      expect(ActivationDataType.values, [
        ActivationDataType.float32,
        ActivationDataType.float16,
      ]);
    });
  });
}

class _FakeClient {
  PreferredBackend? backend;
  bool isShutdown = false;

  void shutdown() {
    isShutdown = true;
  }
}

/// Probes that answer [error] (null: they pass) and record what was asked.
final class _FakeProbes implements NpuProbes {
  _FakeProbes({this.error});

  final String? error;
  final asked = <String>[];

  @override
  String? androidFastRpc() {
    asked.add('androidFastRpc');
    return error;
  }

  @override
  String? linuxQualcommNpu() {
    asked.add('linuxQualcommNpu');
    return error;
  }
}
