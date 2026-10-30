// The example's catalog installs: on core's refusal to write over a file an
// active model reads, the user is asked; on yes the model the refusal names
// is uninstalled and the install runs again, asking again for each further
// model in the way. "Keep it" is a result, not an error, and what fails after
// a model was uninstalled says that it is gone. The refusal's words are
// core's: its golden test/catalog/active_file_refusals.golden.txt, which a
// test below parses.

import 'dart:io';

import 'package:flutter/material.dart';
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

var _calls = 0;

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

  test(
    'a third model removed: the repeated one is not among the gone',
    () async {
      await expectLater(
        installFromCatalogReplacingActive(
          installing([embedder, voice, embedder], []),
          variant: variant,
          confirm: (_, _) async => true,
          uninstall: (_) async {},
        ),
        throwsA(
          isA<CatalogReplaceFailed>().having(
            (e) => e.message,
            'message',
            'Uninstalling emb did not release its file, so ${variant.id} is '
                'not installed; matcha was already uninstalled.',
          ),
        ),
      );
    },
  );

  test('a failure after a replace keeps its own stack', () async {
    final stack = StackTrace.fromString('the download');
    try {
      await installFromCatalogReplacingActive(
        () async {
          if (++_calls == 1) throw embedder;
          Error.throwWithStackTrace(Exception('HTTP 401'), stack);
        },
        variant: variant,
        confirm: (_, _) async => true,
        uninstall: (_) async {},
      );
      fail('no failure');
    } on CatalogReplaceFailed catch (_, st) {
      expect('$st', 'the download');
    }
  });

  test(
    'uninstall() hands core\'s call the file, not the model\'s name',
    () async {
      final model = ActiveModelInTheWay.of(
        refusal('inference', 'gemma', "uninstallModel('gemma-it.litertlm')"),
      )!;
      String? file;
      await model.uninstall(via: (String f) async => file = f);
      expect(file, 'gemma-it.litertlm');
      var called = false;
      await ActiveModelInTheWay.of(
        embedder,
      )!.uninstall(via: () async => called = true);
      expect(called, isTrue);
    },
  );

  test('a call that does not fit its kind is not read as a refusal', () {
    expect(
      ActiveModelInTheWay.of(refusal('inference', 'g', 'uninstallEmbedder()')),
      isNull,
    );
    expect(
      ActiveModelInTheWay.of(
        refusal('embedding', 'e', "uninstallModel('e.tflite')"),
      ),
      isNull,
    );
  });

  test(
    'core\'s own sentences, one per kind, are read with their core call',
    () {
      // Written by core's test/catalog/active_file_refusal_golden_test.dart,
      // which holds them to activeFileRefusal: the example reads core's real
      // wording, not a copy of it.
      final golden = File(
        '../test/catalog/active_file_refusals.golden.txt',
      ).readAsLinesSync().where((l) => l.isNotEmpty).toList();
      final expected = <(String, String, String?, Function)>[
        ('inference', 'gemma', "it's.litertlm", FlutterEdgeAi.uninstallModel),
        ('embedding', 'emb', null, FlutterEdgeAi.uninstallEmbedder),
        ('speech-to-text', 'stt', null, FlutterEdgeAi.uninstallStt),
        ('text-to-speech', 'matcha', null, FlutterEdgeAi.uninstallTts),
      ];
      expect(golden, hasLength(expected.length));
      for (final (i, (kind, name, file, call)) in expected.indexed) {
        final model = ActiveModelInTheWay.of(StateError(golden[i]))!;
        expect(model.kind, kind);
        expect(model.name, name);
        expect(model.inferenceFile, file);
        expect(identical(model.uninstaller, call), isTrue, reason: kind);
      }
    },
  );

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

  testWidgets('the screens show "already uninstalled" first, and only then '
      'the dialog its cause needs', (tester) async {
    final gated = <Object>[];
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    const cause = DownloadException(DownloadError.unauthorized());
    final showing = showInstallErrors(
      context,
      const CatalogReplaceFailed(
        'emb was already uninstalled, but x did not install',
        cause,
      ),
      StackTrace.empty,
      fallback: 'failed',
      gated: (error) async => gated.add(error),
      log: (_) {},
    );
    await tester.pumpAndSettle();
    // The message waits for the user; the gated dialog has not opened.
    expect(
      find.text('emb was already uninstalled, but x did not install'),
      findsOneWidget,
    );
    expect(gated, isEmpty);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await showing;
    expect(gated, [cause]);
  });

  testWidgets('a screen already gone still leaves the message in the log', (
    tester,
  ) async {
    late BuildContext gone;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            gone = c;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(gone.mounted, isFalse);
    final logged = <String>[];
    await showInstallErrors(
      gone,
      const CatalogReplaceFailed('emb was already uninstalled, but x did not'),
      StackTrace.fromString('the download'),
      fallback: 'failed',
      gated: (_) async {},
      log: logged.add,
    );
    expect(logged.single, contains('emb was already uninstalled'));
    expect(logged.single, contains('the download'));
  });
}
