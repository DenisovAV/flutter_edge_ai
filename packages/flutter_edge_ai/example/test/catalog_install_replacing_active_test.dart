// The example's catalog installs: on core's refusal to write over the active
// model's file, the old model is uninstalled and the install runs again.

import 'package:flutter_edge_ai_example/services/catalog_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the refusal uninstalls the old model and installs again', () async {
    var installs = 0;
    var uninstalled = false;
    final result = await installFromCatalogReplacingActive(() async {
      installs++;
      if (!uninstalled) {
        throw StateError(
          'This install would write m.litertlm over the file the active '
          'model m reads, and checks it only afterwards.',
        );
      }
      return 'done';
    }, uninstall: () async => uninstalled = true);
    expect(result, 'done');
    expect(installs, 2);
  });

  test('any other error is the caller\'s', () async {
    var uninstalled = false;
    await expectLater(
      installFromCatalogReplacingActive<void>(
        () async => throw StateError('something else'),
        uninstall: () async => uninstalled = true,
      ),
      throwsStateError,
    );
    expect(uninstalled, isFalse);
  });
}
