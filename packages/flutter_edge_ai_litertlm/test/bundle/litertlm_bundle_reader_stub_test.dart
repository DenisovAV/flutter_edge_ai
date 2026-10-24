// The web arm of readLiteRtLmBundleInfo is plain Dart, so the VM runs it.

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmBundleInfo;
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_bundle_reader_stub.dart'
    as web;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the web arm fails its future, never synchronously, so catchError '
      'sees it', () async {
    late Future<LiteRtLmBundleInfo> read;
    expect(
      () => read = web.readLiteRtLmBundleInfo('model.litertlm'),
      returnsNormally,
    );
    await expectLater(read, throwsUnsupportedError);
    expect(
      await web
          .readLiteRtLmBundleInfo('model.litertlm')
          .then<Object?>((info) => info, onError: (Object e) => e),
      isA<UnsupportedError>(),
    );
  });
}
