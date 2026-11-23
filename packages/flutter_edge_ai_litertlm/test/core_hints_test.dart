// litertlm_dart words its errors in its own API; the adapter adds one line in
// core's terms where it hands them on (lib/src/adapter/core_hints.dart). The
// runtime's own text stays as it is, and the type stays the same.
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/core_hints.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/embedder_core_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal.dart'
    show EmbedderLoadException, LiteRtLmBundleException, LiteRtLmBundleProblem;

void main() {
  group('coreHintFor', () {
    test('a backend becomes preferredBackend', () {
      expect(
        coreHintFor('Load it on the CPU (Backend.cpu()).'),
        'In flutter_edge_ai: preferredBackend: PreferredBackend.cpu, or none.',
      );
    });

    test('two backends are both named, in order', () {
      expect(
        coreHintFor(
          'Load it on the GPU or the CPU (Backend.gpu() or '
          'Backend.cpu()).',
        ),
        'In flutter_edge_ai: preferredBackend: PreferredBackend.gpu or '
        'PreferredBackend.cpu, or none.',
      );
    });

    test('a null encoder backend becomes a support flag left off', () {
      expect(
        coreHintFor(
          'without its encoders (visionBackend: null, '
          'audioBackend: null)',
        ),
        'In flutter_edge_ai: without supportImage or supportAudio.',
      );
    });

    test('the arm64 refusal names the MediaPipe model that still runs', () {
      expect(
        coreHintFor('LiteRT-LM requires an arm64-v8a Android device (got x).'),
        contains('MediaPipe `.task` model'),
      );
    });

    test('the native log setting becomes the engine\'s nativeLogLevel', () {
      expect(
        coreHintFor(
          'LiteRtLmLog.nativeLevel = LiteRtLmLogLevel.verbose shows '
          'its log.',
        ),
        contains('LiteRtLmEngine(nativeLogLevel: LiteRtLmLogLevel.verbose)'),
      );
    });

    test('missing macOS companions name the package whose Swift package '
        'embeds them', () {
      expect(
        coreHintFor("LiteRT-LM's companion libraries are not in the app: …"),
        "In flutter_edge_ai: flutter_edge_ai_litertlm's Swift package embeds "
        'them.',
      );
    });

    test('the web engine\'s missing vision encoder becomes supportImage', () {
      expect(
        coreHintFor(
          'This engine loaded no vision encoder: create it with a '
          'visionBackend to send images.',
        ),
        contains('supportImage: true'),
      );
    });

    test('the web engine\'s missing audio encoder becomes supportAudio', () {
      expect(
        coreHintFor(
          'This engine loaded no audio encoder: create it with an '
          'audioBackend to send audio.',
        ),
        contains('supportAudio: true'),
      );
    });

    test('the web image reservation names getActiveModel(maxNumImages:)', () {
      expect(
        coreHintFor(
          'This conversation holds 1 of the 1 images its engine '
          'reserves per conversation (maxNumImages: 1).',
        ),
        allOf(
          contains('getActiveModel(maxNumImages'),
          contains('maxNumImages: 1'),
        ),
      );
    });

    test('Chrome\'s blob limit names the streaming storage mode', () {
      expect(
        coreHintFor('could not create the engine: ERR_BLOB_OUT_OF_MEMORY'),
        contains('WebStorageMode.streaming'),
      );
    });

    test('a message naming none of the runtime\'s API gets no line', () {
      expect(coreHintFor('The file is incomplete.'), isNull);
    });
  });

  group('withCoreHintError keeps the type and the runtime\'s text', () {
    test('a bundle refusal', () {
      const error = LiteRtLmBundleException(
        LiteRtLmBundleProblem.wrongBackend,
        'Load it on the CPU (Backend.cpu()).',
        path: '/m.litertlm',
      );

      final hinted = withCoreHintError(error) as LiteRtLmBundleException;

      expect(hinted.problem, LiteRtLmBundleProblem.wrongBackend);
      expect(hinted.path, '/m.litertlm');
      expect(
        hinted.message,
        'Load it on the CPU (Backend.cpu()).\n'
        'In flutter_edge_ai: preferredBackend: PreferredBackend.cpu, or none.',
      );
    });

    test('an engine refusal keeps the native code and message', () {
      const error = LiteRtLmEngineCreateException(
        'Load it on the CPU (Backend.cpu()).',
        nativeCode: 13,
        nativeMessage: 'INTERNAL',
      );

      final hinted = withCoreHintError(error) as LiteRtLmEngineCreateException;

      expect(hinted.nativeCode, 13);
      expect(hinted.nativeMessage, 'INTERNAL');
      expect(hinted.message, contains('PreferredBackend.cpu'));
    });

    test('each attempt of a BackendInitException', () {
      final error = BackendInitException(
        attempts: [
          BackendInitAttemptFailure(
            backend: PreferredBackend.gpu,
            error: const LiteRtLmEngineCreateException(
              'Load it on the CPU (Backend.cpu()).',
            ),
            stackTrace: StackTrace.empty,
          ),
        ],
      );

      final hinted = withCoreHintError(error) as BackendInitException;

      expect(
        (hinted.lastAttempt.error as LiteRtLmEngineCreateException).message,
        contains('PreferredBackend.cpu'),
      );
    });

    test('an arm64 UnsupportedError', () {
      final hinted =
          withCoreHintError(
                UnsupportedError(
                  'LiteRT-LM requires an arm64-v8a Android device (got x).',
                ),
              )
              as UnsupportedError;

      expect(hinted.message, contains('MediaPipe `.task` model'));
    });

    test('an ArgumentError keeps its invalid value and name', () {
      final hinted =
          withCoreHintError(
                ArgumentError.value(
                  7,
                  'threadCount',
                  'Load it on the CPU (Backend.cpu()).',
                ),
              )
              as ArgumentError;

      expect(hinted.invalidValue, 7);
      expect(hinted.name, 'threadCount');
      expect(hinted.message, contains('PreferredBackend.cpu'));
    });

    test('a RangeError stays as it is', () {
      final error = RangeError.range(9, 0, 4, 'index', 'Backend.cpu()');

      expect(withCoreHintError(error), same(error));
    });

    test('an error with nothing to add is the same object', () {
      final error = StateError('closed');

      expect(withCoreHintError(error), same(error));
    });
  });

  test('an embedder refusal reaches core with the line in core\'s terms', () {
    final mapped =
        coreEmbedderError(
              const EmbedderLoadException(
                'LiteRT-LM could not run m on the GPU: x. Load it on the CPU '
                'to embed there (Backend.cpu()).',
              ),
            )
            as EmbeddingLoadException;

    expect(
      mapped.message,
      allOf(contains('(Backend.cpu())'), contains('PreferredBackend.cpu')),
    );
  });
}
