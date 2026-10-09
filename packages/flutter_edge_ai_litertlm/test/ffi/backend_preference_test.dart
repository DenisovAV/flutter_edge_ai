import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/backend_preference.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
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
        ffiBackendFallbackOrder(
          PreferredBackend.npu,
          npuDispatchAvailable: true,
        ),
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
        ffiBackendFallbackOrder(
          PreferredBackend.npu,
          npuDispatchAvailable: false,
        ),
        const [PreferredBackend.gpu, PreferredBackend.cpu],
        reason:
            'a backend we cannot run must not be reported as the one we ran',
      );
    });

    test('the rule: Windows always, Android with FastRPC, Linux with a Qualcomm '
        'NPU, nowhere else', () {
      // The predicate rather than `hostShipsNpuDispatch`, because
      // `Platform.operatingSystem` has no override seam — asserting the getter
      // on a macOS runner compares false to false and would pass for an
      // implementation that disabled NPU everywhere.
      expect(npuDispatchShipsFor('windows', androidHasFastRpc: false), isTrue);
      expect(npuDispatchShipsFor('android', androidHasFastRpc: true), isTrue);
      expect(
        npuDispatchShipsFor('android', androidHasFastRpc: false),
        isFalse,
        reason:
            'the Qualcomm stack ships for every arm64 Android build, so the '
            'APK proves nothing about the silicon',
      );
      expect(
        npuDispatchShipsFor(
          'linux',
          androidHasFastRpc: false,
          linuxHasQualcommNpu: true,
        ),
        isTrue,
      );
      expect(
        npuDispatchShipsFor('linux', androidHasFastRpc: true),
        isFalse,
        reason: "Android's probe says nothing about a Linux machine",
      );
      expect(
        npuDispatchShipsFor(
          'macos',
          androidHasFastRpc: true,
          linuxHasQualcommNpu: true,
        ),
        isFalse,
      );
      for (final os in ['macos', 'linux', 'ios', 'fuchsia', '']) {
        expect(
          npuDispatchShipsFor(os, androidHasFastRpc: true),
          isFalse,
          reason: '$os ships no NPU dispatch stack at all',
        );
      }
    });

    test('the FastRPC probe runs on Android only', () {
      // As an eagerly evaluated argument it ran on every host that asked for
      // npu — including Windows, where LoadLibrary walks PATH.
      expect(
        hostShipsNpuDispatch,
        npuDispatchShipsFor(Platform.operatingSystem, androidHasFastRpc: false),
      );
      expect(fastRpcProbed, isFalse);
    }, skip: Platform.isAndroid ? 'the probe is the point on Android' : false);

    test('the Linux probe runs on Linux only', () {
      // It opens device files and dlopens a Qualcomm library; neither belongs
      // on a host where the answer is fixed.
      expect(hostShipsNpuDispatch, isNotNull);
      expect(linuxNpuProbed, isFalse);
    }, skip: Platform.isLinux ? 'the probe is the point on Linux' : false);

    test('the reason npu is missing is worded per platform', () {
      final android = npuUnavailableReason(
        'android',
        fastRpcError: 'dlopen failed: library "libcdsprpc.so" not found',
      );
      expect(android, contains('libcdsprpc.so'));
      expect(android, contains('not found'), reason: 'the probe error is kept');
      expect(
        android,
        isNot(contains('ships')),
        reason: 'the stack does ship on Android; the device lacks FastRPC',
      );

      final linux = npuUnavailableReason(
        'linux',
        fastRpcError:
            '/dev/dma_heap/system is not accessible to this user. '
            'Add the user to group fastrpc',
      );
      expect(linux, contains('group fastrpc'), reason: 'the fix is named');
      expect(linux, isNot(contains('ships')));
      expect(npuUnavailableReason('linux'), contains('no Qualcomm NPU'));

      expect(npuUnavailableReason('macos'), contains('no NPU dispatch stack'));
      expect(npuUnavailableReason('macos'), isNot(contains('FastRPC')));
    });

    test('tries GPU, then CPU for a GPU preference', () {
      expect(ffiBackendFallbackOrder(PreferredBackend.gpu), const [
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      ]);
    });

    test('tries GPU, then CPU when no preference is provided', () {
      expect(ffiBackendFallbackOrder(null), const [
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      ]);
    });

    test('tries only CPU for a CPU preference', () {
      expect(ffiBackendFallbackOrder(PreferredBackend.cpu), const [
        PreferredBackend.cpu,
      ]);
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
          npuDispatchAvailable: true,
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
            npuDispatchAvailable: false,
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

    test('a failed backend is printed, and the last one does not promise a '
        'next', () async {
      final printed = await _printedWithGemmaLogMuted(() async {
        await expectLater(
          initializeFfiRuntime<_FakeClient>(
            preferredBackend: PreferredBackend.gpu,
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
    // The VISION encoder graph carries STABLEHLO_COMPOSITE ops the Metal /
    // WebGPU LiteRT delegates can't prepare (hard-fails at conversation_create,
    // no fallback — LiteRT-LM#2461), so CPU is the op-safe default there. AUDIO
    // runs on either backend; CPU is a conservative default. Both stay
    // overridable: a vision model whose section bakes a gpu-only
    // backend_constraint would otherwise hard-fail on CPU, and Gemma 3n audio is
    // ~2x faster on GPU.
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
