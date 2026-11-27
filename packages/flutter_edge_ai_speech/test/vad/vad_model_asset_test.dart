// Holds the bundled Silero VAD model to the file the package documents, and
// the asset to the pubspec, so a replaced or re-exported model cannot ship
// without these constants (and assets/vad/README.md) being updated with it.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai_speech/src/vad/bundled_vad_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const prefix = 'packages/flutter_edge_ai_speech/';
  final file = File(bundledVadModelAsset.substring(prefix.length));

  test('the asset is the documented file', () {
    expect(bundledVadModelAsset, startsWith(prefix));
    final bytes = file.readAsBytesSync();
    expect(bytes.length, bundledVadModelBytes);
    expect(sha256.convert(bytes).toString(), bundledVadModelSha256);
  });

  test('the pubspec declares it and the licence ships beside it', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec,
      contains('    - ${bundledVadModelAsset.substring(prefix.length)}\n'),
    );
    expect(File('assets/vad/LICENSE.silero_vad').existsSync(), isTrue);
    expect(
      File('assets/vad/README.md').readAsStringSync(),
      contains(bundledVadModelSha256),
    );
  });
}
