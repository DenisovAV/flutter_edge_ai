// The example's catalog installs: on core's refusal to write over a file an
// active model reads, the user is asked; on yes the model the refusal names
// is uninstalled and the install runs again, asking again for each further
// model in the way. "Keep it" is a result, not an error, and what fails after
// a model was uninstalled says that it is gone. The refusal's words are
// core's, held by core's catalog_entries_test.dart.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/services/catalog_install.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core's refusal, as `activeFileRefusal` writes it.
StateError refusal(String kind, String name, String call) => StateError(
  'This install would write x over the file the active $kind model $name '
  'reads, and checks it only afterwards. Uninstall that model first '
  '(FlutterEdgeAi.$call), or install under another file name.',
);

final embedder = refusal('embedding', 'emb', 'uninstallEmbedder()');
final voice = refusal('text-to-speech', 'matcha', 'uninstallTts()');

void main() {
  final variant = LiteRtLmModels.gemma4E2bIt.generic;

  /// An install that throws [errors] in turn, then succeeds.
  Future<void> Function() installing(List<Object> errors, List<int> runs) =>
      () async {
        runs.add(runs.length);
        if (runs.length <= errors.length) throw errors[runs.length - 1];
      };

  test('on yes, the model the refusal names is uninstalled and the install '
      'runs again', () async {
    final runs = <int>[];
    final uninstalled = <String>[];
    final asked = <(String, int)>[];
    final result = await installFromCatalogReplacingActive(
      installing([embedder], runs),
      variant: variant,
      confirm: (model, bytes) async {
        asked.add((model.name, bytes));
        return true;
      },
      uninstall: (model) async =>
          uninstalled.add('${model.kind} ${model.name}'),
    );
    expect(result, isA<CatalogInstalled>());
    expect(runs, hasLength(2));
    expect(asked, [('emb', variant.file.sizeBytes)]);
    expect(uninstalled, ['embedding emb']);
  });

  test('a second model in the way gets the question too', () async {
    final runs = <int>[];
    final asked = <String>[];
    final uninstalled = <String>[];
    final result = await installFromCatalogReplacingActive(
      installing([embedder, voice], runs),
      variant: variant,
      confirm: (model, _) async {
        asked.add(model.name);
        return true;
      },
      uninstall: (model) async => uninstalled.add(model.name),
    );
    expect(result, isA<CatalogInstalled>());
    expect(asked, ['emb', 'matcha']);
    expect(uninstalled, ['emb', 'matcha']);
  });

  test(
    '"keep it" is a result, not an error, and nothing is uninstalled',
    () async {
      var uninstalled = false;
      final result = await installFromCatalogReplacingActive(
        installing([embedder], []),
        variant: variant,
        confirm: (_, _) async => false,
        uninstall: (_) async => uninstalled = true,
      );
      expect(uninstalled, isFalse);
      final kept = result as CatalogInstallKept;
      expect(kept.model.name, 'emb');
      expect(kept.message, 'Kept emb. Nothing was uninstalled or downloaded.');
    },
  );

  test(
    'an uninstall that fails says so, and that nothing downloaded',
    () async {
      final runs = <int>[];
      await expectLater(
        installFromCatalogReplacingActive(
          installing([embedder], runs),
          variant: variant,
          confirm: (_, _) async => true,
          uninstall: (_) async => throw StateError('close timed out'),
        ),
        throwsA(
          isA<CatalogReplaceFailed>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('Could not uninstall emb'),
              endsWith('Nothing was downloaded.'),
            ),
          ),
        ),
      );
      expect(runs, hasLength(1));
    },
  );

  test('a reinstall that fails says the old model is already gone', () async {
    await expectLater(
      installFromCatalogReplacingActive(
        installing([embedder, Exception('HTTP 401')], []),
        variant: variant,
        confirm: (_, _) async => true,
        uninstall: (_) async {},
      ),
      throwsA(
        isA<CatalogReplaceFailed>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              'emb was already uninstalled, but ${variant.id} did '
              'not install',
            ),
            contains('HTTP 401'),
          ),
        ),
      ),
    );
  });

  test('keeping a second model after replacing a first says the first is '
      'gone', () async {
    var asks = 0;
    await expectLater(
      installFromCatalogReplacingActive(
        installing([embedder, voice], []),
        variant: variant,
        confirm: (_, _) async => ++asks == 1,
        uninstall: (_) async {},
      ),
      throwsA(
        isA<CatalogReplaceFailed>().having(
          (e) => e.message,
          'message',
          'emb was already uninstalled; matcha was kept, so ${variant.id} is '
              'not installed.',
        ),
      ),
    );
  });

  test('the same model in the way again is not asked about twice', () async {
    var asks = 0;
    await expectLater(
      installFromCatalogReplacingActive(
        installing([embedder, embedder], []),
        variant: variant,
        confirm: (_, _) async {
          asks++;
          return true;
        },
        uninstall: (_) async {},
      ),
      throwsA(
        isA<CatalogReplaceFailed>().having(
          (e) => e.message,
          'message',
          'Uninstalling emb did not release its file, so ${variant.id} is '
              'not installed.',
        ),
      ),
    );
    expect(asks, 1);
  });

  test('each kind is uninstalled with its own core call', () {
    for (final (kind, call, uninstaller) in [
      ('embedding', 'uninstallEmbedder()', FlutterEdgeAi.uninstallEmbedder),
      ('speech-to-text', 'uninstallStt()', FlutterEdgeAi.uninstallStt),
      ('text-to-speech', 'uninstallTts()', FlutterEdgeAi.uninstallTts),
    ]) {
      final model = ActiveModelInTheWay.of(refusal(kind, 'm', call))!;
      expect(identical(model.uninstaller, uninstaller), isTrue, reason: kind);
    }
  });

  test('two models of different kinds with one name are two models', () async {
    final asked = <String>[];
    final result = await installFromCatalogReplacingActive(
      installing([
        refusal('inference', 'emb', "uninstallModel('emb.litertlm')"),
        embedder,
      ], []),
      variant: variant,
      confirm: (model, _) async {
        asked.add(model.kind);
        return true;
      },
      uninstall: (_) async {},
    );
    expect(result, isA<CatalogInstalled>());
    expect(asked, ['inference', 'embedding']);
  });

  test('an inference model is named with its file, escapes read', () {
    final model = ActiveModelInTheWay.of(
      refusal('inference', 'gemma', r"uninstallModel('it\'s.litertlm')"),
    )!;
    expect(model.kind, 'inference');
    expect(model.name, 'gemma');
    expect(model.inferenceFile, "it's.litertlm");
    for (final (kind, call) in [
      ('speech-to-text', 'uninstallStt()'),
      ('text-to-speech', 'uninstallTts()'),
    ]) {
      expect(ActiveModelInTheWay.of(refusal(kind, 'm', call))?.kind, kind);
    }
  });

  test('any other error is the caller\'s, unasked', () async {
    var asked = false;
    await expectLater(
      installFromCatalogReplacingActive(
        () async => throw StateError('something else'),
        variant: variant,
        confirm: (_, _) async => asked = true,
        uninstall: (_) async {},
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'something else'),
      ),
    );
    expect(asked, isFalse);
  });

  group('what a download screen shows', () {
    const gated = DownloadException(DownloadError.unauthorized());
    const failed = 'Failed to download the model.';

    test('a replace that failed on a 401 says first the old model is gone, '
        'then offers the gated dialog', () {
      final views = installErrorViews(
        const CatalogReplaceFailed(
          'emb was already uninstalled, but x did not install',
          gated,
        ),
        fallback: failed,
      );
      expect(views, hasLength(2));
      expect(
        (views[0] as InstallErrorMessage).text,
        startsWith('emb was already uninstalled'),
      );
      expect((views[1] as InstallErrorGated).error, same(gated));
    });

    test('a replace that failed on a full disk says first the old model is '
        'gone, then offers the storage dialog', () {
      final views = installErrorViews(
        CatalogReplaceFailed(
          'emb was already uninstalled, but x did not install',
          Exception('No space left on device'),
        ),
        fallback: failed,
      );
      expect(views.first, isA<InstallErrorMessage>());
      expect(views.last, isA<InstallErrorStorage>());
    });

    test('a replace that failed otherwise is its message alone', () {
      final views = installErrorViews(
        CatalogReplaceFailed('emb was already uninstalled', Exception('x')),
        fallback: failed,
      );
      expect(views.single, isA<InstallErrorMessage>());
    });

    test('any other error is its dialog, or the screen\'s text', () {
      expect(
        installErrorViews(gated, fallback: failed).single,
        isA<InstallErrorGated>(),
      );
      expect(
        (installErrorViews(Exception('boom'), fallback: failed).single
                as InstallErrorMessage)
            .text,
        failed,
      );
    });
  });
}
