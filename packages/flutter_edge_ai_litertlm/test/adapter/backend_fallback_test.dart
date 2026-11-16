import 'dart:async';

import 'package:flutter_edge_ai_litertlm/src/adapter/backend_fallback.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/runtime_mapping.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:flutter_edge_ai_litertlm/src/litert_lm_load_errors.dart';
import 'package:flutter_edge_ai/engine.dart';
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
  group('initializeFfiRuntime', () {
    test(
      'returns the first successfully initialized fallback backend',
      () async {
        final clients = <_FakeClient>[];

        final runtime = await initializeFfiRuntime<_FakeClient>(
          preferredBackend: PreferredBackend.gpu,
          backends: _fallbackOrder(PreferredBackend.gpu, npuAvailable: false),
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
          backends: _fallbackOrder(PreferredBackend.npu, npuAvailable: true),
          logTag: '[Test]',
          createClient: () {
            final client = _FakeClient();
            clients.add(client);
            return client;
          },
          initializeClient: (client, backend) async {
            client.backend = backend;
            throw Exception('${ffiBackendWireName(backend.toRuntime)} failed');
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
            backends: _fallbackOrder(PreferredBackend.npu, npuAvailable: false),
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
            backends: _fallbackOrder(PreferredBackend.gpu, npuAvailable: false),
            logTag: '[Test]',
            createClient: _FakeClient.new,
            initializeClient: (_, backend) async => throw Exception(
              '${ffiBackendWireName(backend.toRuntime)} failed',
            ),
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
            backends: _fallbackOrder(PreferredBackend.cpu, npuAvailable: false),
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
}

/// The runtime's fallback order, in core's backends.
List<PreferredBackend> _fallbackOrder(
  PreferredBackend requested, {
  required bool npuAvailable,
}) => [
  for (final backend in ffiBackendFallbackOrder(
    requested.toRuntime,
    npuAvailable: npuAvailable,
  ))
    backend.toCore,
];

class _FakeClient {
  PreferredBackend? backend;
  bool isShutdown = false;

  void shutdown() {
    isShutdown = true;
  }
}
