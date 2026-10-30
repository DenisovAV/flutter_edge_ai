// The example's catalog installs: on core's refusal to write over a file an
// active model reads, the user is asked; on yes the model the refusal names
// is uninstalled and the install runs again. The refusal's words are core's,
// held by core's catalog_entries_test.dart.

import 'package:flutter_edge_ai_example/services/catalog_install.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core's refusal, as `activeFileRefusal` writes it.
StateError refusal(String kind, String name, String call) => StateError(
  'This install would write x over the file the active $kind model $name '
  'reads, and checks it only afterwards. Uninstall that model first '
  '(FlutterEdgeAi.$call), or install under another file name.',
);

void main() {
  final variant = LiteRtLmModels.gemma4E2bIt.generic;

  test('on yes, the model the refusal names is uninstalled and the install '
      'runs again', () async {
    var installs = 0;
    final uninstalled = <ActiveModelInTheWay>[];
    final asked = <(String, int)>[];
    final result = await installFromCatalogReplacingActive(
      () async {
        installs++;
        if (uninstalled.isEmpty) {
          throw refusal('embedding', 'emb', 'uninstallEmbedder()');
        }
        return 'done';
      },
      variant: variant,
      confirm: (model, bytes) async {
        asked.add((model.name, bytes));
        return true;
      },
      uninstall: (model) async => uninstalled.add(model),
    );
    expect(result, 'done');
    expect(installs, 2);
    expect(asked, [('emb', variant.file.sizeBytes)]);
    expect(uninstalled.single.kind, 'embedding');
  });

  test('an inference model is named with its file', () {
    final model = ActiveModelInTheWay.of(
      refusal('inference', 'gemma', "uninstallModel('gemma.litertlm')"),
    )!;
    expect(model.kind, 'inference');
    expect(model.name, 'gemma');
    expect(model.inferenceFile, 'gemma.litertlm');
    for (final (kind, call) in [
      ('speech-to-text', 'uninstallStt()'),
      ('text-to-speech', 'uninstallTts()'),
    ]) {
      expect(ActiveModelInTheWay.of(refusal(kind, 'm', call))?.kind, kind);
    }
  });

  test(
    'on no, nothing is uninstalled and the refusal is the caller\'s',
    () async {
      var uninstalled = false;
      await expectLater(
        installFromCatalogReplacingActive<void>(
          () async =>
              throw refusal('inference', 'g', "uninstallModel('g.bin')"),
          variant: variant,
          confirm: (_, _) async => false,
          uninstall: (_) async => uninstalled = true,
        ),
        throwsStateError,
      );
      expect(uninstalled, isFalse);
    },
  );

  test('any other error is the caller\'s, unasked', () async {
    var asked = false;
    await expectLater(
      installFromCatalogReplacingActive<void>(
        () async => throw StateError('something else'),
        variant: variant,
        confirm: (_, _) async => asked = true,
        uninstall: (_) async {},
      ),
      throwsStateError,
    );
    expect(asked, isFalse);
  });
}
